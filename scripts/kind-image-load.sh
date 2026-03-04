#!/usr/bin/env bash
# scripts/kind-image-load.sh
#
# kind-tilt-study 클러스터에 이미지를 직접 로드한다.
#
# 배경:
#   kind-tilt-study 클러스터는 rootful podman으로 생성되었고
#   Kind 노드 컨테이너(tilt-study-control-plane)는 인터넷 경로가 없어
#   ttl.sh 레지스트리에서 직접 pull 이 불가하다.
#   (기존 Tiltfile 주석: "ttl.sh는 kind 노드가 인터넷을 통해 pull 가능하므로 호환"
#    → 실제로는 Kind 노드 podman 네트워크에서 외부 TCP 연결 불가로 인해 불가능.)
#
# 해결책:
#   1. 호스트의 rootless podman으로 ttl.sh 이미지를 pull (호스트는 인터넷 가능)
#   2. Docker archive 형식으로 /tmp에 저장
#   3. 특권 파드(privileged pod)를 kube-system에 생성
#      - kube-proxy 이미지(Kind 노드에 캐시됨) 사용 → 인터넷 필요 없음
#      - Kind 노드의 /host(루트 파일시스템)와 containerd 소켓 마운트
#   4. kubectl exec로 tar를 파드에 스트리밍
#   5. 파드 내 /host/usr/local/bin/ctr로 containerd에 import
#   6. 올바른 name:tag로 tag 생성
#   7. 파드 삭제 및 .tilt-ko-image-ref에서 digest 제거
#
# 사용법:
#   IMAGE_REF=<full ref with digest>
#   bash scripts/kind-image-load.sh "$IMAGE_REF"
#
# 또는 Tiltfile에서 자동으로 호출됨.

set -euo pipefail

IMAGE_REF="${1:?Usage: $0 <image-ref-with-digest>}"
IMAGE_NO_DIGEST="${IMAGE_REF%@sha256:*}"
CLUSTER_NAME="tilt-study"
HELPER_POD="kind-img-loader"
HELPER_NS="kube-system"
HELPER_IMAGE="registry.k8s.io/kube-proxy:v1.31.0"
TMP_TAR="/tmp/kind-image-load-$$.tar"

echo "[kind-image-load] 이미지 로드 시작"
echo "  ref:      $IMAGE_REF"
echo "  tag-only: $IMAGE_NO_DIGEST"

# 1. 이미지가 rootless podman에 이미 있는지 확인, 없으면 pull
if ! podman image exists "$IMAGE_REF" 2>/dev/null; then
  echo "[kind-image-load] ttl.sh에서 이미지 pull 중..."
  podman pull "$IMAGE_REF"
fi

# 2. Docker archive 형식으로 저장
echo "[kind-image-load] Docker archive로 저장 중: $TMP_TAR"
podman save "$IMAGE_REF" -o "$TMP_TAR"
echo "[kind-image-load] 저장 완료: $(du -sh "$TMP_TAR" | cut -f1)"

# 3. 기존 helper pod 정리
kubectl delete pod "$HELPER_POD" -n "$HELPER_NS" --ignore-not-found 2>/dev/null

# 4. 특권 파드 생성
echo "[kind-image-load] containerd import 파드 생성 중..."
kubectl apply -f - <<PODEOF
apiVersion: v1
kind: Pod
metadata:
  name: $HELPER_POD
  namespace: $HELPER_NS
spec:
  nodeName: ${CLUSTER_NAME}-control-plane
  restartPolicy: Never
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: helper
    image: $HELPER_IMAGE
    command: ["sh", "-c", "sleep 120"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-root
      mountPath: /host
    - name: containerd-sock
      mountPath: /run/containerd/containerd.sock
  volumes:
  - name: host-root
    hostPath:
      path: /
  - name: containerd-sock
    hostPath:
      path: /run/containerd/containerd.sock
      type: Socket
PODEOF

# 파드 Ready 대기
echo "[kind-image-load] 파드 Ready 대기..."
kubectl wait pod -n "$HELPER_NS" "$HELPER_POD" --for=condition=Ready --timeout=30s

# 5. tar 스트리밍
echo "[kind-image-load] 이미지 tarball 스트리밍 중..."
cat "$TMP_TAR" | kubectl exec -i -n "$HELPER_NS" "$HELPER_POD" -- sh -c "cat > /host/tmp/kind-load.tar"

# 6. containerd import
echo "[kind-image-load] containerd에 import 중..."
kubectl exec -n "$HELPER_NS" "$HELPER_POD" -- sh -c \
  "/host/usr/local/bin/ctr -n k8s.io --address=/run/containerd/containerd.sock images import /host/tmp/kind-load.tar 2>&1"

# 7. 이미지 ID 찾기 및 tag 추가
# 주의: awk/head 는 kube-proxy 컨테이너 내에 미존재.
#       ctr images list 출력을 호스트에서 처리하여 sha256 참조를 추출한다.
echo "[kind-image-load] tag 추가 중..."
IMAGES_LIST=$(kubectl exec -n "$HELPER_NS" "$HELPER_POD" -- \
  /host/usr/local/bin/ctr -n k8s.io --address=/run/containerd/containerd.sock images list 2>&1)
# 호스트에서 awk/head 실행 (kube-proxy 컨테이너 내부 의존 없음)
IMAGE_ID=$(echo "$IMAGES_LIST" | grep -v 'registry.k8s.io' | grep -v 'docker.io' | \
  grep -v 'import-' | awk '{print $1}' | grep '^sha256:' | head -1)

if [ -n "$IMAGE_ID" ]; then
  echo "[kind-image-load] 이미지 ID: $IMAGE_ID → tag: $IMAGE_NO_DIGEST"
  kubectl exec -n "$HELPER_NS" "$HELPER_POD" -- \
    /host/usr/local/bin/ctr -n k8s.io --address=/run/containerd/containerd.sock \
    images tag "$IMAGE_ID" "$IMAGE_NO_DIGEST" 2>&1 || true
else
  echo "[kind-image-load] sha256 참조 없음 (import 시 직접 태그됨, 건너뜀)"
fi

# 8. 정리
echo "[kind-image-load] 파드 삭제..."
kubectl delete pod "$HELPER_POD" -n "$HELPER_NS" --ignore-not-found 2>/dev/null
rm -f "$TMP_TAR"

echo "[kind-image-load] 완료: $IMAGE_NO_DIGEST 가 Kind 노드 containerd에 로드됨"
