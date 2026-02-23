# Tiltfile

# 안전장치: 다른 클러스터에 실수로 배포 방지
allow_k8s_contexts('kind-tilt-study')

KIND_CLUSTER_NAME = 'tilt-study'
KO_DOCKER_REPO = 'kind.local'

# 1 kustomize로 YAML 생성 -> Tilt가 apply/상태추적/로그수집까지 담당
#k8s_yaml(kustomize('config/default'))
k8s_yaml(kustomize('config/overlays/kind'))

# 2 ko로 이미지 빌드(그리고 kind에 로드)한 "최종 이미지 ref"를 파일로 저장
#    Tilt는 outputs_image_ref_to 파일을 읽어서 YAML의 image: controller:latest 를 자동 치환함.
# --- build config (pulled up) ---
custom_build_image = 'controller'
custom_build_cmd = (
  "bash -lc 'set -euo pipefail; "
  + "export KO_DOCKER_REPO={repo}; "
  + "export KIND_CLUSTER_NAME={cluster}; "
  + "ko build ./cmd > .tilt-ko-image-ref'"
).format(repo=KO_DOCKER_REPO, cluster=KIND_CLUSTER_NAME)
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

# 4 버튼: 샘플 CR 적용/삭제 (kubectl apply -f 디렉터리 말고 파일로!)
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