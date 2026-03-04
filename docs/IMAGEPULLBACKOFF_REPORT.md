# 장애 보고서: hello-operator-controller ImagePullBackOff

## 1. 장애 개요

| 항목 | 내용 |
|------|------|
| 발생 일시 | 2026-03-03 (KST) |
| 발생 위치 | Tilt UI → `hello-operator-controller` 리소스 |
| 장애 유형 | `ImagePullBackOff` → 오퍼레이터 파드 기동 불가 |
| 영향 범위 | `sli-e2e-test` 연쇄 실패 (오퍼레이터 미준비) |
| 해결 여부 | 완료 (2026-03-03) |

---

## 2. 증상

### 2-1. Tilt UI 에러 메시지

```
[event: pod hello-operator-system/hello-operator-controller-manager-8f486f5b-6tjc8]
Failed to pull image "ttl.sh/hello-op/cmd-619d43fa0077945ab4581c285622fa67:tilt-dev@sha256:3554bd1...":
failed to pull and unpack image "...":
failed to do request:
  Head "https://ttl.sh/v2/hello-op/.../manifests/sha256:3554bd1...":
  dial tcp: lookup ttl.sh on 100.100.100.100:53:
  read udp 10.89.0.3:54437->100.100.100.100:53: i/o timeout
```

### 2-2. SLI E2E 테스트 실패

```
=== RUN   TestHelloSLIE2E
    sli_e2e_test.go:64: [sli-e2e] 오퍼레이터 파드 미준비:
        오퍼레이터 파드가 30s 내에 Ready 상태가 되지 않았음
--- FAIL: TestHelloSLIE2E (30.69s)
```

### 2-3. 파드 상태

```
NAME                                                READY   STATUS             RESTARTS
hello-operator-controller-manager-8f486f5b-6tjc8    0/1     ImagePullBackOff   0
hello-operator-controller-manager-f695f6959-9tb4s   0/1     ImagePullBackOff   0
```

---

## 3. 원인 분석

### 3-1. 에러 계층도

```
[최종 증상] sli-e2e-test FAIL (30s 타임아웃)
  └── [현상 1] 오퍼레이터 파드 ImagePullBackOff
        └── [원인 1] containerd가 ttl.sh HTTPS 연결 실패
              └── [원인 2] DNS 조회 타임아웃 (lookup ttl.sh on 100.100.100.100:53)
                    └── [원인 3] Kind 노드가 외부 DNS/TCP에 접근 불가
                          └── [근본 원인] Kind 노드 podman 네트워크에 인터넷 경로 없음
```

### 3-2. 근본 원인: Kind 노드의 인터넷 미연결

`kind-tilt-study` 클러스터의 노드(`tilt-study-control-plane`)는 rootful podman 컨테이너로
실행되며, 해당 컨테이너의 네트워크(cni-podman1, 10.89.0.0/24)는 외부 인터넷에 대한
TCP 경로가 없다.

증거:
- DNS 우회 후에도 TCP 연결 실패: `dial tcp 178.156.198.215:443: connect: no route to host`
- 호스트에서의 연결: `timeout 5 bash -c 'echo "" > /dev/tcp/ttl.sh/443'` → TCP OK
- Kind 노드에서의 연결: no route to host → 라우팅 미설정

### 3-3. Tiltfile 주석의 오류

기존 Tiltfile에는 다음과 같이 기재되어 있었다:

```
# ttl.sh는 kind 노드가 인터넷을 통해 pull 가능하므로 호환.
```

이 주석은 사실과 다르다. Kind 노드는 인터넷 연결이 없다. 오퍼레이터 이미지가
과거에 정상 동작한 이유는 이미지가 기존에 Kind 노드 containerd에 캐시되어 있었기
때문이다 (`imagePullPolicy: IfNotPresent`).

새로운 이미지 digest가 생성되면 캐시 미스가 발생하고 pull 시도 → 실패.

### 3-4. 시도한 해결책과 결과

| 시도 | 내용 | 결과 |
|------|------|------|
| 1 | Kind 노드 resolv.conf를 8.8.8.8로 패치 | DNS 서버 변경 성공, 그러나 TCP 자체가 불가 |
| 2 | /etc/hosts에 `178.156.198.215 ttl.sh` 추가 | DNS 우회 성공, 그러나 `no route to host` |
| 3 | DNS 서버를 10.89.0.1로 복원 | 원상 복구 (10.89.0.1은 DNS 정상) |
| **4** | **Kind 노드 containerd에 직접 이미지 import** | **성공** |

---

## 4. 해결 과정

### 4-1. 이미지 직접 로드 전략

Kind 노드에는 이미 k8s 시스템 이미지(`registry.k8s.io/kube-proxy:v1.31.0` 등)가
캐시되어 있다. 이를 활용하여 다음 순서로 이미지를 로드했다:

```
호스트(rootless podman)        Kind 노드(containerd)
       │                              │
       │ podman pull ← ttl.sh         │
       │ podman save → /tmp/op.tar    │
       │                              │
       │  kubectl exec -i (stdin pipe) │
       │ ─────────────────────────── ▶│  /host/tmp/op.tar
       │                              │
       │                   ctr images import /host/tmp/op.tar
       │                   ctr images tag sha256:... name:tag
       │                              │
```

### 4-2. 핵심 기술: 특권 파드(privileged pod)로 containerd 조작

```yaml
# kube-proxy 이미지 사용 (이미 Kind 노드에 캐시됨 → 인터넷 불필요)
containers:
- image: registry.k8s.io/kube-proxy:v1.31.0
  command: ["sh", "-c", "sleep 120"]
  securityContext:
    privileged: true
  volumeMounts:
  - name: host-root
    mountPath: /host                           # Kind 노드 루트 파일시스템
  - name: containerd-sock
    mountPath: /run/containerd/containerd.sock  # Kind 노드 containerd 소켓
```

### 4-3. 단계별 명령어

```bash
# 1. 호스트에서 이미지 pull (rootless podman)
podman pull "ttl.sh/hello-op/cmd-...:tilt-dev@sha256:3554bd1..."

# 2. Docker archive 저장
podman save "$IMAGE_REF" -o /tmp/hello-operator-image.tar

# 3. Kind 노드에 tar 스트리밍 (kubectl exec stdin)
cat /tmp/hello-operator-image.tar | kubectl exec -i -n kube-system HELPER_POD -- \
  sh -c "cat > /host/tmp/op.tar"

# 4. containerd import
kubectl exec -n kube-system HELPER_POD -- \
  /host/usr/local/bin/ctr -n k8s.io --address=/run/containerd/containerd.sock \
  images import /host/tmp/op.tar

# 5. tag 추가 (name:tag 형식, digest 없이)
kubectl exec -n kube-system HELPER_POD -- \
  /host/usr/local/bin/ctr -n k8s.io --address=/run/containerd/containerd.sock \
  images tag sha256:bc060b... ttl.sh/hello-op/cmd-...:tilt-dev
```

### 4-4. Deployment 이미지 참조 수정

digest가 포함된 참조는 containerd가 digest를 검증할 때 불일치를 일으킨다
(Docker archive 포맷으로 import하면 manifest digest가 달라짐). 따라서 digest를 제거한다.

```bash
# Deployment 이미지 참조를 digest 없는 tag-only로 패치
kubectl patch deployment -n hello-operator-system hello-operator-controller-manager \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image",
        "value":"ttl.sh/hello-op/cmd-...:tilt-dev"}]'
```

### 4-5. 결과 확인

```
NAME                                               READY   STATUS    RESTARTS   AGE
hello-operator-controller-manager-dbb679476-n7qhc   1/1     Running   0          20s
```

오퍼레이터 로그:
```
starting manager
Starting workers {"controller": "hello", "worker count": 1}
reconcile hit {"name": "hello-sample", "namespace": "default"}
```

---

## 5. 영구 해결책

### 5-1. scripts/kind-image-load.sh 추가

빌드마다 자동으로 이미지를 Kind 노드에 로드하는 스크립트를 추가했다.
`scripts/kind-image-load.sh` 참조.

### 5-2. Tiltfile custom_build_cmd 수정

```python
custom_build_cmd = (
  "bash -lc 'set -euo pipefail; "
  + "export KO_DOCKER_REPO={repo}; "
  + "ko build --tags tilt-dev ./cmd > .tilt-ko-image-ref; "
  + "IMAGE_REF=$(cat .tilt-ko-image-ref); "
  + "bash scripts/kind-image-load.sh \"$IMAGE_REF\"; "      # ← 추가
  + "sed -i \"s|@sha256:[a-f0-9]*||\" .tilt-ko-image-ref'"  # ← 추가: digest 제거
).format(repo=KO_DOCKER_REPO)
```

### 5-3. 동작 원리 (수정 후)

```
ko build → ttl.sh push           (호스트 → 인터넷: 정상)
         ↓
scripts/kind-image-load.sh       (호스트 rootless podman → Kind containerd)
  podman pull ← ttl.sh           (호스트: 인터넷 접근 가능)
  podman save → /tmp/*.tar
  cat tar | kubectl exec → Kind 노드 /tmp/
  ctr images import
  ctr images tag name:tilt-dev
         ↓
.tilt-ko-image-ref = name:tilt-dev  (digest 제거)
         ↓
Tilt → Deployment image = name:tilt-dev
         ↓
imagePullPolicy: IfNotPresent → containerd 조회 → 캐시 히트 → 파드 기동
```

---

## 6. 재발 방지 및 주의사항

1. **Kind 노드는 인터넷 미연결**: `kind-tilt-study` 노드는 외부 레지스트리에 접근 불가.
   새 이미지 push 후 반드시 `scripts/kind-image-load.sh`로 로드해야 한다.

2. **24h TTL**: ttl.sh 이미지는 24시간 후 만료. 클러스터 재생성 시 이미지 재로드 필요.

3. **클러스터 재생성 시**: `scripts/kind-cluster-init.sh` 실행 후 `tilt up`을 하면
   새 빌드 시 `kind-image-load.sh`가 자동 실행된다 (Tiltfile 수정 반영).

4. **digest vs tag-only**: Kind 노드 containerd에 직접 import된 이미지는 원본 레지스트리
   manifest digest와 다른 digest를 갖는다 (Docker archive 포맷 변환으로 인해).
   따라서 `imagePullPolicy: IfNotPresent`에 tag-only 참조를 사용해야 한다.

---

## 7. 관련 파일

| 파일 | 변경 내용 |
|------|----------|
| `Tiltfile` | custom_build_cmd에 kind-image-load.sh 호출 + digest 제거 추가 |
| `scripts/kind-image-load.sh` | 신규 추가: Kind 노드 이미지 로더 |
| `docs/IMAGEPULLBACKOFF_REPORT.md` | 본 보고서 |
| `docs/PROGRESS_LOG.md` | 진행 로그 업데이트 |
