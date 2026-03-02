# Tiltfile
#
# Step 1-F: kind-tilt-study 클러스터 복구 완료.
# - 클러스터: rootful podman(관리자 권한)으로 생성된 tilt-study kind 클러스터.
# - 레지스트리: ttl.sh/hello-op (ephemeral, 24h TTL).
#   kind.local은 rootful/rootless podman 권한 분리로 인해 ko와 직접 연동 불가.
#   ttl.sh는 kind 노드가 인터넷을 통해 pull 가능하므로 호환.
# - 오버레이: config/overlays/kind (imagePullPolicy: IfNotPresent).

# 안전장치: kind 클러스터에만 배포 허용
allow_k8s_contexts('kind-tilt-study')

KO_DOCKER_REPO = 'ttl.sh/hello-op'

# 1 kustomize로 YAML 생성 -> Tilt가 apply/상태추적/로그수집까지 담당
k8s_yaml(kustomize('config/overlays/kind'))

# 2 ko로 이미지 빌드 후 ttl.sh에 푸시, "최종 이미지 ref"를 파일로 저장
#    Tilt는 outputs_image_ref_to 파일을 읽어서 YAML의 image: controller:latest 를 자동 치환함.
#    주의: --tags tilt-dev 필수. Tilt는 순수 digest ref(@sha256:...)를 거부함.
# --- build config ---
custom_build_image = 'controller'
custom_build_cmd = (
  "bash -lc 'set -euo pipefail; "
  + "export KO_DOCKER_REPO={repo}; "
  + "ko build --tags tilt-dev ./cmd > .tilt-ko-image-ref'"
).format(repo=KO_DOCKER_REPO)
custom_build_deps = ['cmd', 'api', 'internal', 'go.mod', 'go.sum']
custom_build_outputs = '.tilt-ko-image-ref'
custom_build_skips_local_docker = True

# --- build hook ---
custom_build(
  custom_build_image,
  custom_build_cmd,
  deps=custom_build_deps,
  outputs_image_ref_to=custom_build_outputs,
  skips_local_docker=custom_build_skips_local_docker,
)

# 3 오퍼레이터 리소스를 Tilt UI에서 보기 좋게 + 포트포워딩
# 로그를 보면 metrics는 :8443(secure), health는 :8081
k8s_resource(
  'hello-operator-controller-manager',
  port_forwards=['8081:8081', '8443:8443'],
)

# 4 버튼: 샘플 CR 적용/삭제
local_resource(
  'apply-sample',
  cmd='kubectl --context kind-tilt-study apply -f config/samples/demo_v1alpha1_hello.yaml',
  auto_init=False,
)

local_resource(
  'delete-sample',
  cmd='kubectl --context kind-tilt-study delete -f config/samples/demo_v1alpha1_hello.yaml --ignore-not-found',
  auto_init=False,
)

# 5 kube-slint Phase 1: Mock 기반 SLI 파이프라인 검증 (클러스터 불필요)
#    실제 K8s 클러스터 없이 kube-slint 하네스 측정 로직을 로컬에서 검증한다.
#    httptest.Server로 /metrics 응답을 모의하여 reconcile_total_delta = 3 여부 확인.
local_resource(
  'sli-mock-test',
  cmd='go test ./test/e2e/ -run TestHelloSLIMock -v -count=1 -timeout 30s',
  auto_init=False,
  deps=['test/e2e/sli_integration_test.go'],
)

# 6 kube-slint Phase 2: curlpod fetcher 기반 실제 클러스터 SLI 측정
#    hello-operator-sli-checker SA의 Bearer 토큰으로 HTTPS /metrics 엔드포인트 접근.
#    CR 생성 후 reconcile_total_delta >= 1 검증.
#    전제조건: 오퍼레이터 배포 완료, sli-checker RBAC 적용 완료.
local_resource(
  'sli-e2e-test',
  cmd='E2E_SLI=1 go test ./test/e2e/ -run TestHelloSLIE2E -v -tags e2e -count=1 -timeout 3m',
  auto_init=False,
  deps=['test/e2e/sli_e2e_test.go'],
)