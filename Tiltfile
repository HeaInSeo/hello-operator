# Tiltfile

# Step 1-E: kind-tilt-study 클러스터 생성 불가(rootless cgroup 위임 미완료)로
# 기존 클러스터(kubernetes-admin@kubernetes)를 사용하는 vm 경로로 전환.
# 레지스트리: ttl.sh (ephemeral, 24h TTL) - kind.local 대체.
# 원래 kind 설정은 아래 주석으로 보존.
#
# Original kind settings (blocked):
#   allow_k8s_contexts('kind-tilt-study')
#   KO_DOCKER_REPO = 'kind.local'
#   k8s_yaml(kustomize('config/overlays/kind'))

# 안전장치: 기존 VM 클러스터 허용
allow_k8s_contexts('kubernetes-admin@kubernetes')

KO_DOCKER_REPO = 'ttl.sh/hello-op'

# 1 kustomize로 YAML 생성 -> Tilt가 apply/상태추적/로그수집까지 담당
k8s_yaml(kustomize('config/overlays/vm'))

# 2 ko로 이미지 빌드 후 ttl.sh에 푸시, "최종 이미지 ref"를 파일로 저장
#    Tilt는 outputs_image_ref_to 파일을 읽어서 YAML의 image: controller:latest 를 자동 치환함.
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
  cmd='kubectl apply -f config/samples/demo_v1alpha1_hello.yaml',
  auto_init=False,
)

local_resource(
  'delete-sample',
  cmd='kubectl delete -f config/samples/demo_v1alpha1_hello.yaml --ignore-not-found',
  auto_init=False,
)