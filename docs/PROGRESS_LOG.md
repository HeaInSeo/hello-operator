# PROGRESS_LOG

## [Technical Baseline]
- 아키텍처: Remote-first 개발 (Kind 클러스터: kind-tilt-study)
  - Step 1-F: rootful podman(관리자 권한)으로 kind-tilt-study 클러스터 생성 완료.
  - 클러스터 재생성: `bash scripts/kind-cluster-init.sh` (관리자 권한 필요).
  - 참고: `kubernetes-admin@kubernetes` 클러스터(vm 경로)도 대안으로 사용 가능.
- 빌드/배포: `ko` 기반 이미지 빌드 + `Tilt` 오케스트레이션
  - 레지스트리: `ttl.sh/hello-op` (ephemeral, 24h TTL)
  - 이미지 ref 포맷: `ttl.sh/hello-op/cmd-<hash>:tilt-dev@sha256:<digest>`
  - ko 빌드 시 `--tags tilt-dev` 필수 (Tilt outputs_image_ref_to는 태그 포함 ref 요구)
  - kind.local 미사용: rootful/rootless podman 권한 분리로 ko 직접 연동 불가
- 검증 파이프라인: Tilt inner-loop 기반 배포 + 샘플 CR reconcile 로그 확인
- 로컬 격리 도구 경로:
  - 설치 스크립트: `scripts/install-tools.sh`
  - 클러스터 초기화: `scripts/kind-cluster-init.sh` (관리자 권한 필요)
  - 로컬 바이너리: `./bin/tilt v0.35.0`, `./bin/ko 0.17.1`, `./bin/kind 0.24.0`
  - PATH 적용: `export PATH=$(pwd)/bin:$PATH`
- 노트북에서 Tilt UI 접근 방법 (2가지):
  - 방법 A (Tailscale 직접 접속, 현재 설정 완료):
    - 서버: `tilt up --host 0.0.0.0 --port 10350`
    - 노트북 브라우저: `http://100.92.45.46:10350/`
    - 전제: 방화벽 10350/tcp 영구 개방 완료, Tailscale 연결 중
  - 방법 B (SSH 터널, 방화벽 변경 불필요):
    - 노트북: `ssh -L 10350:localhost:10350 heain@<서버IP>`
    - 서버: `tilt up --port 10350` (--host 생략 가능)
    - 노트북 브라우저: `http://localhost:10350/`
  - 상세 설명: `docs/TROUBLESHOOTING_STEP1.md` 섹션 8 참조
- SSH 포트 포워딩 기준 (확정):
  - Tilt UI: `localhost:10350 -> remote:10350`
  - Health probe: `localhost:8081 -> remote:8081`
  - Metrics(secure, HTTPS): `localhost:8443 -> remote:8443`
  - Webhook: `localhost:9443 -> remote:9443` (webhook 활성화 시)
- 클러스터 토폴로지:
  - Dev host: `172.30.1.83`, k8s gateway: `10.87.127.1`
  - kind master: `tilt-study-control-plane`, kind v0.24.0, k8s v1.31.0
  - VM backup cluster: `k8s-master-0` @ `10.87.127.29`, v1.35.1, containerd 1.7.28
  - 인터넷 접근 가능 (ttl.sh pull 양측 검증 완료)
- cgroup 위임 영구화 (관리자 권한으로 적용):
  - `/etc/tmpfiles.d/rootless-cgroup-delegate.conf`: 부팅 시 user.slice subtree_control 활성화
  - `/etc/systemd/system/user.slice.d/delegate.conf`: Delegate=yes
  - `/etc/systemd/system/user@.service.d/delegate.conf`: Delegate=yes

### 현재 저장소 기반 보강
- Kubebuilder 스캐폴드 구조 확인: `api/v1alpha1`, `internal/controller`, `config/*`, `test/e2e`.
- `Tiltfile` (Step 1-F 복원 후 현재 상태):
  - `allow_k8s_contexts('kind-tilt-study')` - kind 클러스터 허용.
  - `KO_DOCKER_REPO = 'ttl.sh/hello-op'` - ephemeral 레지스트리.
  - `k8s_yaml(kustomize('config/overlays/kind'))` - kind 오버레이 사용.
  - `ko build --tags tilt-dev ./cmd` - 태그 포함 이미지 ref 출력.
  - `apply-sample`/`delete-sample` 로컬 리소스 제공.
- `hack/kind-init.sh`:
  - `KO_DOCKER_REPO=kind.local`, `KIND_CLUSTER_NAME=tilt-study`, `KUBECONTEXT=kind-tilt-study` 참조용.
- `config/overlays`:
  - `kind`: `imagePullPolicy: IfNotPresent`, replicas 1 - 현재 사용 중.
  - `vm`: 매니저 리소스 requests/limits 강화(500m/512Mi, 2CPU/2Gi) - 대안 경로.
- `config/default`/`config/rbac`:
  - metrics endpoint 보호용 authn/authz RBAC(`metrics_auth_role`, `metrics_reader_role`) 포함.
  - Prometheus 관련 리소스는 기본 비활성(주석) 상태.
- `Makefile`:
  - `make test`(envtest 기반), `make test-e2e`(Kind 기반), `make lint`, `make deploy/undeploy` 제공.
- `docs/TROUBLESHOOTING_STEP1.md`:
  - cgroup v2 위임 실패 원인, 해결 절차, 로그 해석법을 초보자 대상으로 기술.

### 현재 갭
- kube-slint: `github.com/HeaInSeo/kube-slint v1.0.0-rc.1` 확인. Go 라이브러리 기반 E2E 하네스.
  DX 감사 완료: `docs/KUBE_SLINT_DX_AUDIT.md` 참조.
  주요 갭: curlpod TLS 인증서 검증, RBAC 설정 필요, CurlImage 커스터마이징 미노출.
- Tilt 원격 UI 접근: 방화벽 포트 10350/tcp 개방 완료. `tilt up --host 0.0.0.0 --port 10350` 사용.
  Tailscale 접속 URL: `http://100.92.45.46:10350/`.
- Tilt inner-loop 내 SLI 자동 체크 파이프라인은 Phase 1(Mock) → Phase 2(curlpod) → Phase 3(Tiltfile) 순서로 진행 예정.
- ttl.sh 이미지 TTL: 24h. 장기 개발 시 로컬 레지스트리 또는 영구 레지스트리로 전환 권장.
- kind 클러스터 재생성 시 관리자 권한 필요 (`scripts/kind-cluster-init.sh` 참조).
- SSH 포트 포워딩 및 원격 UI 접근 트러블슈팅: `docs/TROUBLESHOOTING_STEP1.md` 섹션 8 참조.

## [Roadmap]
- Step 1: [Completed] Tilt/ko/Kind 환경 통합, 스모크 테스트, 트러블슈팅 문서화
  - 원격 Tilt UI 접근: 방화벽 포트 10350 개방, TROUBLESHOOTING 섹션 8 추가
  - kube-slint DX 감사: docs/KUBE_SLINT_DX_AUDIT.md 완료
- Step 2: SLI 계측 도구 통합 (kube-slint v1.0.0-rc.1 기반)
  - Phase 1: [Completed] Mock Fetcher 기반 단위 테스트 (클러스터 불필요)
  - Phase 2: [Completed] curlpod Fetcher + RBAC 설정 + Tiltfile local_resource 연동
  - Phase 3: [Completed] 실 클러스터 E2E_SLI=1 검증 (2026-03-04)
- Step 3: Tiltfile 고도화 (Inner-loop 내 SLI 자동 체크 기능 추가)
- Step 4: 환경별 Kustomize 오버레이(kind/vm) 정교화 및 배포 검증

## [Current Task]
- 목표: Step 2 Phase 3 완료 (실 클러스터 E2E_SLI=1 검증)
- 체크리스트 (Step 1 완료):
  - [x] `scripts/install-tools.sh` 작성 및 실행 권한 부여
  - [x] `./bin` 로컬 설치 완료(`tilt`, `ko`, `kind`)
  - [x] `.gitignore`에 `bin/` 포함 확인
  - [x] `export PATH=$(pwd)/bin:$PATH` 기준 툴 버전 검증
  - [x] kind 클러스터 생성 (rootful podman + 관리자 권한으로 해결)
  - [x] cgroup 위임 영구화 (tmpfiles.d + systemd drop-in)
  - [x] `tilt ci` 기반 kind-tilt-study 배포 + reconcile 로그 채집
  - [x] `docs/TROUBLESHOOTING_STEP1.md` 작성
  - [x] `scripts/kind-cluster-init.sh` 작성

### Step 2 설계 초안 (kube-slint Readiness)

**현황 파악 결과 (2026-03-02):**
- `kube-slint`는 공개된 표준 Kubernetes 도구로 존재하지 않음.
  - 유사 도구: `kube-linter` (stackrox, YAML 정적 분석), Prometheus SLO 도구들.
  - 결론: Step 2에서 프로젝트 전용 SLI 계측 스크립트/도구를 설계해야 함.
- GitHub raw URL 접근: 가능 (HTTP 200/301 확인).
- 컨트롤러 메트릭 엔드포인트: `:8443` (HTTPS, `Serving metrics server` 확인).

**Step 2 RBAC 설계 초안 (메트릭 읽기 권한):**

SLI 계측 도구가 컨트롤러 메트릭을 외부에서 읽으려면 아래 RBAC가 필요하다.
현재 `config/rbac/metrics_reader_role.yaml`에 이미 기본 틀이 존재한다.

```yaml
# 제안: config/rbac/sli-reader-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: hello-operator-sli-reader
rules:
- nonResourceURLs:
  - /metrics
  - /healthz
  - /readyz
  verbs:
  - get
---
# 메트릭 수집 ServiceAccount 바인딩
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: hello-operator-sli-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hello-operator-sli-reader
subjects:
- kind: ServiceAccount
  name: sli-checker
  namespace: hello-operator-system
```

**Step 2 Tiltfile 통합 제안:**
```python
local_resource(
  'sli-check',
  cmd='kubectl exec -n hello-operator-system ... -- curl -sk https://localhost:8443/metrics | grep hello_',
  auto_init=False,
)
```

**Step 2 최소 구현 목표:**
- [ ] SLI 체크 스크립트 작성 (`scripts/sli-check.sh`)
- [ ] RBAC 추가 (`config/rbac/sli-reader-role.yaml`)
- [ ] Tiltfile local_resource 연동
- [ ] kube-linter 연동 검토 (YAML 정적 분석)
- 샘플 삭제 후 finalizer/정리 동작 확인.

5. 최소 검증 결과 고정
- `kubectl get pods -n hello-operator-system`, `kubectl get hellos.demo.example.com -A` 결과 기록.
- 실패 시 원인 분류(컨텍스트, 이미지 빌드, RBAC, CRD 순서) 및 재현 커맨드 기록.

## [Work Log]
- 2026-02-28: 초기 세팅 수행.
  - 수행 내용:
    - `docs/PROGRESS_LOG.md` 신규 생성.
    - `Tiltfile`, `Makefile`, `hack/kind-init.sh`, `config/default`, `config/overlays`, `config/rbac`, `README.md` 스캔.
    - Remote-first + ko/Tilt/Kind 기준 및 kube-slint 통합 갭 정리.
    - Step 1 실행 계획 수립.
  - 이슈:
    - 기본 샌드박스에서 명령 실행이 차단되어 권한 상승 실행으로 전환.
  - 검증:
    - 저장소 내 핵심 파일 존재 및 내용 확인 완료 (`Tiltfile`, `Makefile`, `config/*`, `api/*`, `test/*`).
    - PROGRESS_LOG 구조/섹션 생성 완료.
    - 섹션 검증 명령 결과: `Technical Baseline(3), Roadmap(30), Current Task(36), Work Log(67)` 라인에 정상 존재 확인.
- 2026-02-28: 문서 GitHub 업로드 수행.
  - 수행 내용:
    - `docs/PROGRESS_LOG.md` 커밋 생성.
    - `origin/main`으로 푸시 완료.
  - 검증:
    - 커밋: `e27b150` (`docs: add progress log baseline and step 1 plan`)
    - 푸시 결과: `main -> main` 반영 확인.
- 2026-02-28: Step 1 실행(원격 환경 점검 + 기동 시도).
  - 수행 내용:
    - `Tiltfile`, `Makefile`, `hack/kind-init.sh` 재확인.
    - 도구/컨텍스트 점검:
      - `kind`: `/home/heain/bin/kind`은 `sudo` 래퍼, 실바이너리 `/usr/local/bin/kind` 확인.
      - `tilt`: PATH 미존재.
      - `ko`: PATH 미존재.
      - `kubectl`: 클라이언트 v1.35.0, 현재 컨텍스트 `kubernetes-admin@kubernetes`.
      - kind 클러스터 목록: 없음.
    - kind 생성 시도: `/usr/local/bin/kind create cluster --name tilt-study` 실행.
  - 이슈:
    - kind rootless provider 제약으로 클러스터 생성 실패:
      - `running kind with rootless provider requires setting systemd property "Delegate=yes"`.
    - `tilt`, `ko` 미설치로 `tilt up` 단계 진입 불가.
    - 요청 컨텍스트(`kind-tilt-study`) 부재.
  - 해결/대응:
    - 즉시 적용 가능한 우회는 제한적이며, Step 1 완료 전제조건 정리:
      1. `tilt` 설치
      2. `ko` 설치
      3. kind 실행 경로 정상화(루트리스 podman `Delegate=yes` 설정 또는 sudo 가능한 kind wrapper 사용)
      4. `tilt-study` 클러스터 생성 후 `kind-tilt-study` 컨텍스트 확보
  - 검증:
    - `/usr/local/bin/kind --version` => `0.32.0-alpha+9145d421e0d4f7`
    - `kubectl get nodes -o wide` => `k8s-master-0 Ready`(기존 클러스터 접속 가능)
    - `tilt up --stream=true --host 0.0.0.0 --port 10350` => `/bin/bash: tilt: command not found`
    - `ko version` => `/bin/bash: ko: command not found`
    - `kubectl config get-contexts -o name | rg '^kind-tilt-study$'` => 컨텍스트 없음
  - 정상 로그 패턴 박제(비교 기준):
    - 컨트롤러 startup 기준 (`cmd/main.go`):
      - `setup` 로거의 `starting manager`
    - Reconcile 기준 (`internal/controller/hello_controller.go`):
      - `reconcile hit` + key `name=<namespace>/<name>`
    - Step 1 완료 시 기대 패턴:
      - `hello-operator-controller-manager` 파드 `Running/Ready`
      - 샘플 CR apply 직후 `reconcile hit` 로그 반복 관측
- 2026-02-28: Step 1-C 스크립트 기반 로컬 툴링 설치 및 재검증.
  - 수행 내용:
    - `scripts/install-tools.sh` 신규 작성:
      - Tilt/ko/kind를 GitHub release에서 `./bin`으로 설치
      - 실행 권한 부여
      - `.gitignore`에 `bin/` 자동 추가 로직 포함
    - 스크립트 실행 완료 후 PATH 전환:
      - `export PATH=$(pwd)/bin:$PATH`
  - 검증:
    - `./bin/tilt version` => `v0.35.0`
    - `./bin/ko version` => `0.17.1`
    - `./bin/kind --version` => `0.24.0`
    - `.gitignore`에서 `bin/` 엔트리 확인 (`31:bin/`)
    - `kind create cluster --name tilt-study` => 실패
      - 원인: `running kind with rootless provider requires setting systemd property "Delegate=yes"`
    - `tilt up --stream=true --host 0.0.0.0 --port 10350` => 실행은 시작되나 중단
      - 로그 핵심:
        - `Tilt started on http://127.0.0.1:10350/`
        - `ERROR: Stop! kubernetes-admin@kubernetes might be production.`
        - Tiltfile의 `allow_k8s_contexts('kind-tilt-study')` 가드로 배포 차단
  - Delegate=yes 이슈 해결안(권장 순서):
    1. 관리자 권한으로 user@.service drop-in 설정
       - `/etc/systemd/system/user@.service.d/delegate.conf`:
         - `[Service]`
         - `Delegate=yes`
       - 적용:
         - `sudo systemctl daemon-reload`
         - `sudo systemctl restart user@$(id -u)`
    2. 사용자 세션 podman 서비스 재기동:
       - `systemctl --user daemon-reload`
       - `systemctl --user restart podman.service`
    3. 재검증:
       - `export PATH=$(pwd)/bin:$PATH`
       - `kind create cluster --name tilt-study`
       - `kubectl config get-contexts -o name | rg '^kind-tilt-study$'`
  - 정상 로그 패턴(실측/기준):
    - 실측(`tilt up`):
      - `Tilt started on http://127.0.0.1:10350/`
      - `Stop! kubernetes-admin@kubernetes might be production`
    - 실제 Reconcile 로그:
      - 이번 실행에서는 kind 컨텍스트 부재로 수집 불가
      - 기준 패턴(코드 기준): `reconcile hit` + `name=<namespace>/<name>`
- 2026-02-28: Step 1-D 인프라 복구 시도(Delegate + kind 기동).
  - 수행 내용:
    - 로컬 도구 우선 사용 확인:
      - `export PATH=$(pwd)/bin:$PATH`
      - `tilt v0.35.0`, `ko 0.17.1`, `kind 0.24.0`
    - Delegate 적용 지시 수행 시도:
      - `/etc/systemd/system/user@.service.d/delegate.conf` 생성/적용 명령 실행 시도
      - `sudo systemctl daemon-reload`
      - `sudo systemctl restart user@$(id -u)`
      - `systemctl --user restart podman.service`
    - kind 생성/컨텍스트 확보 시도:
      - `kind create cluster --name tilt-study`
      - `kubectl config use-context kind-tilt-study`
    - `source hack/kind-init.sh` 후 `tilt up --host 0.0.0.0 --port 10350` 실행 시도
  - 이슈:
    - sudo 비밀번호 요구로 시스템 경로 수정 차단:
      - `sudo: a terminal is required to read the password`
      - `sudo: a password is required`
    - rootless kind 생성 실패 지속:
      - `running kind with rootless provider requires setting systemd property "Delegate=yes"`
    - user-level 우회(`systemctl --user start podman.socket`, `DOCKER_HOST=/run/user/<uid>/podman/podman.sock`) 후에도 동일 실패.
    - `tilt up`는 시작되지만 kind 컨텍스트 부재로 배포 차단:
      - `Stop! kubernetes-admin@kubernetes might be production`
  - 검증:
    - `systemctl show user@$(id -u).service -p Delegate` => `Delegate=yes` 표시
    - `systemctl --user show podman.service -p Delegate` => `Delegate=yes`
    - `kind create cluster --name tilt-study` => 실패(Delegate 오류)
    - `kubectl config get-contexts -o name | rg '^kind-tilt-study$'` => 미존재
    - `tilt up` 실측 로그:
      - `Tilt started on http://127.0.0.1:10350/`
      - `[Docker Prune] ... /run/podman/podman.sock ... permission denied`
      - `ERROR: Stop! kubernetes-admin@kubernetes might be production.`
  - 정상 로그 패턴(실측 결과):
    - Startup:
      - 이번 단계에서는 `cmd/main.go`의 `starting manager` 미관측(클러스터/컨텍스트 미구성으로 배포 미진입)
    - Reconcile:
      - 이번 단계에서는 `reconcile hit` 미관측(샘플 CR 적용 불가)
  - 상태:
    - Step 1 = `Blocked` (권한 의존 인프라 설정 미완료)
- 2026-03-02: Step 1-E 인프라 복구 - VM 클러스터 대안 경로 실행 완료.
  - 수행 내용:
    - kind rootless 차단 근본 원인 확정:
      - `/sys/fs/cgroup/user.slice/cgroup.subtree_control` 비어있음.
      - `user.slice` 경로 파일 소유자 root(r--r--r--), 사용자 수정 불가.
      - `Delegate=yes` systemd 설정은 반영됐으나 cgroup subtree_control 자동 위임 미발생.
    - 대안 경로 확정: 기존 `kubernetes-admin@kubernetes` 클러스터 활용.
      - 클러스터 구성: `k8s-master-0` (Ubuntu 24.04, k8s v1.35.1, containerd 1.7.28).
      - 인터넷 접근 확인: `alpine:latest` 이미지 pull 테스트 성공.
    - `Tiltfile` 수정:
      - `allow_k8s_contexts('kubernetes-admin@kubernetes')` 로 컨텍스트 전환.
      - `KO_DOCKER_REPO = 'ttl.sh/hello-op'` 로 레지스트리 전환(ephemeral, 24h TTL).
      - `k8s_yaml(kustomize('config/overlays/vm'))` 로 오버레이 전환.
      - `ko build --tags tilt-dev` 추가: Tilt outputs_image_ref_to 태그 포함 ref 요구 해소.
    - `tilt ci` 실행:
      - Namespace, CRD, RBAC, Deployment, Service 순차 apply 완료.
      - ko 빌드: ttl.sh 푸시 성공 (8초 이내).
      - 이미지 ref: `ttl.sh/hello-op/cmd-619d43fa0077945ab4581c285622fa67:tilt-dev@sha256:cecc7c4d...`
      - 파드 `hello-operator-controller-manager-64f8f4c86b-zfnf4` Running/Ready (19초 이내).
    - 샘플 CR 적용:
      - `kubectl apply -f config/samples/demo_v1alpha1_hello.yaml` 성공.
      - reconcile 로그 2회 관측(create 시 + delete 시).
      - `kubectl delete -f config/samples/demo_v1alpha1_hello.yaml` 정상 삭제.
  - 검증:
    - `kubectl get pods -n hello-operator-system` => `1/1 Running`
    - `kubectl get hellos.demo.example.com -A` => `default hello-sample` 생성/삭제 확인
    - `tilt ci` 종료 코드 => `0` (SUCCESS. All workloads are healthy.)
  - 정상 로그 패턴 기준 (실측 박제):
    - Startup 시퀀스 (`cmd/main.go` 기반):
      ```
      2026-03-02T06:27:13Z  INFO  setup  starting manager
      2026-03-02T06:27:13Z  INFO  controller-runtime.metrics  Starting metrics server
      2026-03-02T06:27:13Z  INFO  setup  disabling http/2
      2026-03-02T06:27:13Z  INFO  starting server  {"name": "health probe", "addr": "[::]:8081"}
      I0302 06:27:13.361316  leaderelection.go:271  successfully acquired lease hello-operator-system/36afcd4c.example.com
      2026-03-02T06:27:13Z  INFO  Starting EventSource  {"controller": "hello", "controllerKind": "Hello"}
      2026-03-02T06:27:13Z  INFO  controller-runtime.metrics  Serving metrics server  {"bindAddress": ":8443", "secure": true}
      2026-03-02T06:27:13Z  INFO  Starting Controller  {"controller": "hello", "controllerKind": "Hello"}
      2026-03-02T06:27:13Z  INFO  Starting workers  {"controller": "hello", "controllerKind": "Hello", "worker count": 1}
      ```
    - Reconcile 패턴 (`internal/controller/hello_controller.go`):
      ```
      2026-03-02T06:27:31Z  INFO  reconcile hit  {"controller": "hello", "controllerGroup": "demo.example.com", "controllerKind": "Hello", "Hello": {"name":"hello-sample","namespace":"default"}, "namespace": "default", "name": "hello-sample", "reconcileID": "23cb46da-918b-45d7-a154-6d1d37f457ae", "name": {"name":"hello-sample","namespace":"default"}}
      ```
  - 상태:
    - Step 1 = `Completed` (VM 클러스터 경로로 완료)
- 2026-03-02: Step 1-F kind 클러스터 복구 + 트러블슈팅 문서화 완료.
  - 수행 내용:
    - cgroup v2 위임 실패 근본 원인 최종 확정:
      - `user.slice/cgroup.subtree_control` 비어있음 (controllers available but not delegated).
      - `session-99.scope` 직접 수정 시도: `Device or resource busy` (활성 프로세스 존재로 불가).
      - Kind 내부 검증(validateProvider): 현재 세션 스코프의 Delegate 속성 확인 방식 -> rootless 경로 차단.
    - 관리자 권한(Administrative privileges) 적용:
      - `/sys/fs/cgroup/user.slice/cgroup.subtree_control` 및 `user-1001.slice` 즉각 수정.
      - 영구화: `/etc/tmpfiles.d/rootless-cgroup-delegate.conf`, systemd drop-in 생성, daemon-reload.
    - Kind 클러스터 생성: rootful podman(`DOCKER_HOST=unix:///run/podman/podman.sock`) + 관리자 권한.
      - `sudo env KIND_EXPERIMENTAL_PROVIDER=podman DOCKER_HOST=unix:///run/podman/podman.sock ./bin/kind create cluster --name tilt-study`
      - 성공: `Set kubectl context to "kind-tilt-study"`
    - Kubeconfig 병합: root의 `/root/.kube/config`에서 kind-tilt-study 컨텍스트 추출 및 heain kubeconfig에 병합.
    - Tiltfile 복원: `kind-tilt-study` 컨텍스트 + `config/overlays/kind` 오버레이 + `ttl.sh/hello-op` 레지스트리.
    - `tilt ci` on kind-tilt-study: `SUCCESS. All workloads are healthy.` (EXIT 0)
    - 샘플 CR 적용: `reconcile hit` 로그 확인.
    - `scripts/kind-cluster-init.sh` 작성 (클러스터 재생성 자동화).
    - `docs/TROUBLESHOOTING_STEP1.md` 작성 (초보자 대상, cgroup 비유 포함).
    - kube-slint readiness 평가: 공개 표준 도구 미존재 확인, Step 2 설계 초안 작성.
  - 검증:
    - `kubectl get nodes --context kind-tilt-study` => `tilt-study-control-plane Ready`
    - `tilt ci` exit => `0` (kind-tilt-study, kind overlay)
    - `reconcile hit` 실측 로그 (kind-tilt-study):
      ```
      2026-03-02T07:01:43Z  INFO  reconcile hit
        {"controller":"hello","Hello":{"name":"hello-sample","namespace":"default"},
         "reconcileID":"7523ad67-2ead-4c49-b50e-d19838e19d02"}
      ```
    - `/etc/tmpfiles.d/rootless-cgroup-delegate.conf` 생성 확인
    - GitHub raw URL 접근: HTTP 200/301 응답 확인
  - 상태:
    - Step 1 = `Completed` (kind-tilt-study 경로로 최종 완료)
    - 트러블슈팅 문서 = `docs/TROUBLESHOOTING_STEP1.md` 완료
    - Step 2 설계 초안 = `[Current Task]` 섹션에 반영
- 2026-03-02: 원격 Tilt UI 접근 설정 + kube-slint DX 감사.
  - 수행 내용:
    - 방화벽 포트 10350/tcp 영구 개방 (관리자 권한 적용):
      - `sudo firewall-cmd --permanent --add-port=10350/tcp`
      - `sudo firewall-cmd --reload`
    - kube-slint 저장소 확인: `github.com/HeaInSeo/kube-slint v1.0.0-rc.1`
      - Go 라이브러리 기반 SLI 측정 프레임워크 (비침투적 설계)
      - `go get github.com/HeaInSeo/kube-slint@latest` 성공 (hello-operator go.mod에 추가)
    - kube-slint 핵심 패키지 탐색:
      - `test/e2e/harness`: SessionConfig, NewSession, Start, End, DefaultV3Specs
      - `pkg/slo/spec`: SLISpec, MetricRef, ComputeSpec, Rule 타입
      - `test/e2e/harness/discovery.go`: .slint.yaml 설정 파일 자동 탐색
    - `docs/TROUBLESHOOTING_STEP1.md` 섹션 8 추가: 원격 Tilt UI 접근
      - "우편함/경비원" 비유를 통한 네트워크 바인딩 개념 설명
      - 방법 A(방화벽 포트 개방), 방법 B(SSH 터널) 제공
    - `docs/KUBE_SLINT_DX_AUDIT.md` 신규 작성:
      - 설치 경험, API 사용성, 통합 복잡도, 문서 품질, 갭 분석, 통합 계획 포함
      - 주요 발견: curlpod TLS 검증 우회 옵션 없음, CurlImage 커스터마이징 미노출,
        RBAC 설정 예시 미제공 (높은 우선순위 갭)
  - 검증:
    - `firewall-cmd --list-ports` => `988/tcp 10350/tcp` (포트 개방 확인)
    - `go get github.com/HeaInSeo/kube-slint@latest` => `v1.0.0-rc.1` 추가 확인
    - `cat go.mod | grep kube-slint` => 의존성 반영 확인
    - Tailscale 접속 URL: `http://100.92.45.46:10350/` (tilt up --host 0.0.0.0 시 사용)
  - 상태:
    - 원격 Tilt UI 접근 = `설정 완료` (방화벽 포트 개방, 문서화 완료)
    - kube-slint DX 감사 = `완료` (docs/KUBE_SLINT_DX_AUDIT.md)
    - Step 2 착수 준비 = Phase 1(Mock 기반 단위 테스트) 즉시 가능
- 2026-03-02: Step 2 Phase 2 - curlpod Fetcher + RBAC 설정 완료.
  - 수행 내용:
    - kube-slint 최신 커밋(58c0d88) 확인: `TLSInsecureSkipVerify`, `CurlImage` SessionConfig 노출 완료.
    - `config/rbac/sli_checker_serviceaccount.yaml` 작성:
      - SA `sli-checker` (kustomize 후: `hello-operator-sli-checker`, ns: `hello-operator-system`)
    - `config/rbac/sli_checker_clusterrolebinding.yaml` 작성:
      - `sli-checker` SA를 기존 `metrics-reader` ClusterRole에 바인딩.
      - kustomize 후: CRB `hello-operator-sli-checker-metrics-reader`, roleRef `hello-operator-metrics-reader`.
    - `config/rbac/kustomization.yaml` 업데이트: 새 파일 2개 추가.
    - `test/e2e/sli_e2e_test.go` 작성 (//go:build e2e + E2E_SLI=1 가드):
      - `kubectl create token hello-operator-sli-checker`로 Bearer 토큰 발급.
      - `harness.NewSession`에 `TLSInsecureSkipVerify: true`, `ServiceAccountName`, `Token` 주입.
      - 오퍼레이터 파드 Ready 대기 → CR 적용 → 5초 대기 → session.End().
      - `reconcile_total_delta >= 1`, `reconcile_error_delta = 0` 검증.
      - E2E_SLI 미설정 시 Skip (회귀 방지).
    - `Tiltfile` 업데이트: `sli-e2e-test` local_resource 추가 (auto_init=False).
  - 검증:
    - `kubectl kustomize config/overlays/kind | grep sli-checker` => `hello-operator-sli-checker` SA + CRB 확인
    - `go vet -tags e2e ./test/e2e/` => 컴파일 오류 없음
    - `go test -tags e2e -run TestHelloSLIE2E ./test/e2e/` (E2E_SLI 미설정) => SKIP 동작 확인
    - `go test ./test/e2e/ -run TestHelloSLIMock` => PASS (회귀 없음)
  - 실행 방법 (실제 클러스터 사용 시):
    ```bash
    # 1. 오퍼레이터 배포 (RBAC 포함)
    kubectl apply -k config/overlays/kind
    # 또는 tilt up 으로 기동

    # 2. E2E SLI 테스트 실행
    E2E_SLI=1 go test ./test/e2e/ -run TestHelloSLIE2E -v -tags e2e -timeout 3m
    # 또는 Tilt UI에서 sli-e2e-test 버튼 클릭
    ```
  - 상태:
    - Step 2 Phase 2 = `Completed` (RBAC + E2E 테스트 + Tiltfile 연동)
    - Step 2 Phase 3 (실 클러스터 검증) = 오퍼레이터 기동 후 즉시 실행 가능
- 2026-03-03: SLI 계측 결과 JSON 저장 활성화 + kube-slint 회귀 탐지 갭 분석.
  - 수행 내용:
    - `test/e2e/sli_integration_test.go` SessionConfig에 `ArtifactsDir: "/tmp/sli-results"` 추가.
    - `test/e2e/sli_e2e_test.go` SessionConfig에 `ArtifactsDir: "/tmp/sli-results"` 추가.
    - 저장 파일명 패턴: `sli-summary.hello-operator-sli.hello-sample-create.json`
    - kube-slint 회귀 탐지 갭 분석 수행 및 `docs/KUBE_SLINT_DX_AUDIT.md`에 추가.
      - 갭 A: reconcile_error_delta JudgeSpec 주석 처리 (presets.go:52)
      - 갭 B: 레이블 부분 일치 미지원 (engine 수준, 갭 A 효과 무력화)
      - 갭 C: workqueue_depth_end ComputeMode 불일치 (ComputeSingle vs 권장 ComputeEnd)
      - 갭 D: cross-run 회귀 탐지(baseline 비교) 부재 (신규 pkg/slo/regression 필요)
      - 갭 E: GateOnLevel 기본값 "none" (hello-operator SessionConfig 설정 필요)
  - 검증:
    - `go vet ./test/e2e/` => 컴파일 오류 없음
    - `go test ./test/e2e/ -run TestHelloSLIMock -v -timeout 30s` => PASS (ArtifactsDir 추가 후 회귀 없음)
    - `/tmp/sli-results/` 디렉토리에 JSON 파일 생성 확인 (테스트 실행 후)
  - 상태:
    - SLI JSON 저장 = `활성화` (두 테스트 파일 모두 ArtifactsDir 설정 완료)
    - kube-slint 갭 분석 = `완료` (docs/KUBE_SLINT_DX_AUDIT.md [Update 2026-03-03] 섹션)
    - 다음 단계 = kube-slint 갭 A+B+E 해결 (presets.go Judge 주석 해제 + 레이블 매칭 개선)
- 2026-03-04: Step 2 Phase 3 - 실 클러스터 E2E_SLI=1 검증 완료.
  - 수행 내용:
    - curlpod `ImagePullBackOff` 원인 분석:
      - `curlimages/curl:latest` → imagePullPolicy: Always (Kubernetes 기본값) → kind 노드 pull 시도 → docker.io 접근 불가 (no route to host)
      - 해결: `curlimages/curl:kind-cached` 태그(non-latest) 사용 → imagePullPolicy: IfNotPresent
      - kind 노드 containerd에 사전 로드 (privileged pod + ctr images import + tag)
    - `sli_e2e_test.go` `snapshotFetcher` 패턴 도입:
      - 근본 원인: `session.Start()`가 메트릭을 pre-fetch하지 않고 `End()` 내부에서 두 번의 fetch가 모두 post-reconcile 상태를 반환 → delta=0
      - 해결: 테스트에서 직접 curlpod를 두 번 실행(CR 적용 전/후)하여 `snapshotFetcher`로 주입
      - `snapshotFetcher`: `MetricsFetcher` 구현체, 첫 번째 Fetch() = 사전 수집 start, 두 번째 = end 반환
    - `scripts/kind-image-load.sh` 버그 수정:
      - `awk`/`head`를 kube-proxy 컨테이너 내부(kubectl exec)에서 실행 → exit code 127
      - 수정: ctr 출력을 호스트로 전달 후 호스트에서 awk/head 처리
    - `docs/KUBE_SLINT_DX_AUDIT.md` [Update 2026-03-04] 섹션 추가:
      - 갭 F: curlpod imagePullPolicy 미설정 (air-gapped 환경 차단)
      - 갭 G: session.Start() 미스냅샷 (curlpod delta=0 설계 불일치)
      - 버그: kind-image-load.sh awk/head 컨테이너 내부 실행
    - `docs/IMAGEPULLBACKOFF_REPORT.md` 신규: ImagePullBackOff 장애 분석 보고서
    - Tilt UI 복구: tilt up --host 0.0.0.0 --port 10350 재시작 (PID 3051898)
  - 검증:
    - `E2E_SLI=1 go test ./test/e2e/ -run TestHelloSLIE2E -v -tags e2e` → PASS (16.06s)
    - `reconcile_total_delta=1` (VERIFIED >= 1)
    - `workqueue_adds_total_delta=1`, `workqueue_depth_end=0`, `rest_client_requests_total_delta=5`
    - curlpod: `curlimages/curl:kind-cached` already present on machine (pull 없음)
    - `/tmp/sli-results/` JSON 아티팩트 생성 확인
    - Tilt UI http://100.92.45.46:10350/ 접근 가능
  - 상태:
    - Step 2 Phase 3 = `Completed` (실 클러스터 SLI E2E 검증 완료)
    - kube-slint 신규 갭 F, G 발견 및 문서화 완료
    - 다음 단계: Step 3 (Tiltfile 고도화) 또는 kube-slint 갭 A+B+E 해결
