# PROGRESS_LOG

## [Technical Baseline]
- 아키텍처: Remote-first 개발 (VM 클러스터: kubernetes-admin@kubernetes)
  - kind 경로(kind-tilt-study)는 rootless cgroup 위임 미완료로 차단 상태.
  - 현재 운용 경로: 기존 k8s 클러스터(k8s-master-0, Ubuntu 24.04, containerd) 사용.
- 빌드/배포: `ko` 기반 이미지 빌드 + `Tilt` 오케스트레이션
  - 레지스트리: `ttl.sh/hello-op` (ephemeral, 24h TTL) - kind.local 대체
  - 이미지 ref 포맷: `ttl.sh/hello-op/cmd-<hash>:tilt-dev@sha256:<digest>`
  - ko 빌드 시 `--tags tilt-dev` 필수 (Tilt outputs_image_ref_to는 태그 포함 ref 요구)
- 검증: `kube-slint` 원격 참조(예: GitHub raw URL) 기반 Shift-left SLI 계측을 CI/inner-loop에 조기 통합
- 로컬 격리 도구 경로:
  - 설치 스크립트: `scripts/install-tools.sh`
  - 로컬 바이너리: `./bin/tilt v0.35.0`, `./bin/ko 0.17.1`, `./bin/kind 0.24.0`
  - PATH 적용: `export PATH=$(pwd)/bin:$PATH`
- SSH 포트 포워딩 기준 (확정):
  - Tilt UI: `localhost:10350 -> remote:10350`
  - Health probe: `localhost:8081 -> remote:8081`
  - Metrics(secure, HTTPS): `localhost:8443 -> remote:8443`
  - Webhook: `localhost:9443 -> remote:9443` (webhook 활성화 시)
- 클러스터 토폴로지:
  - Dev host: `172.30.1.83`, k8s gateway: `10.87.127.1`
  - k8s master: `k8s-master-0` @ `10.87.127.29`, v1.35.1, containerd 1.7.28
  - 양측 모두 인터넷 접근 가능(ttl.sh pull 검증 완료)

### 현재 저장소 기반 보강
- Kubebuilder 스캐폴드 구조 확인: `api/v1alpha1`, `internal/controller`, `config/*`, `test/e2e`.
- `Tiltfile` (Step 1-E 수정 후 현재 상태):
  - `allow_k8s_contexts('kubernetes-admin@kubernetes')` - VM 클러스터 허용.
  - `KO_DOCKER_REPO = 'ttl.sh/hello-op'` - ephemeral 레지스트리.
  - `k8s_yaml(kustomize('config/overlays/vm'))` - vm 오버레이 사용.
  - `ko build --tags tilt-dev ./cmd` - 태그 포함 이미지 ref 출력.
  - `apply-sample`/`delete-sample` 로컬 리소스 제공.
- `hack/kind-init.sh`:
  - `KO_DOCKER_REPO=kind.local`, `KIND_CLUSTER_NAME=tilt-study`, `KUBECONTEXT=kind-tilt-study`를 source 방식으로 로드(kind 경로용, 현재 미사용).
- `config/overlays`:
  - `kind`: `imagePullPolicy: IfNotPresent`, replicas 1 (kind 경로용, 현재 미사용).
  - `vm`: 매니저 리소스 requests/limits 강화(500m/512Mi, 2CPU/2Gi) - 현재 사용 중.
- `config/default`/`config/rbac`:
  - metrics endpoint 보호용 authn/authz RBAC(`metrics_auth_role`, `metrics_reader_role`) 포함.
  - Prometheus 관련 리소스는 기본 비활성(주석) 상태.
- `Makefile`:
  - `make test`(envtest 기반), `make test-e2e`(Kind 기반), `make lint`, `make deploy/undeploy` 제공.

### 현재 갭
- kind 경로 차단: rootless podman cgroup 위임 미완료 (`/sys/fs/cgroup/user.slice/cgroup.subtree_control` 빈 상태, root 권한 필요).
- `kube-slint` 원격 리소스 참조 및 실행 루틴은 아직 저장소에 통합되지 않음.
- Tilt inner-loop 내 SLI 자동 체크 파이프라인은 아직 미구현.
- ttl.sh 이미지 TTL: 24h. 장기 개발 시 로컬 레지스트리 또는 영구 레지스트리로 전환 필요.

## [Roadmap]
- Step 1: [Completed] 현재 리포지토리의 Tilt/ko/VM 환경 통합 및 스모크 테스트
- Step 2: kube-slint 원격 리소스(GitHub) 참조 및 RBAC 설정 통합
- Step 3: Tiltfile 고도화 (Inner-loop 내 SLI 자동 체크 기능 추가)
- Step 4: 환경별 Kustomize 오버레이(kind/vm) 정교화 및 배포 검증

## [Current Task]
- 목표: Step 2(kube-slint 원격 리소스 통합) 진입 준비
- 체크리스트:
  - [x] `scripts/install-tools.sh` 작성 및 실행 권한 부여
  - [x] `./bin` 로컬 설치 완료(`tilt`, `ko`, `kind`)
  - [x] `.gitignore`에 `bin/` 포함 확인
  - [x] `export PATH=$(pwd)/bin:$PATH` 기준 툴 버전 검증
  - [x] `kind create cluster --name tilt-study` 재시도 (차단: cgroup 위임 미완료)
  - [x] `tilt up` 재시도 및 실패 원인 수집
  - [x] Step 1-D Delegate 설정 적용 시도(권한 제약 확인)
  - [x] Step 1-D kind/podman 우회 시도(유저 소켓 포함)
  - [x] Step 1-E VM 클러스터 대안 경로로 전환 완료
  - [x] Step 1 완전 성공(tilt ci 기반 기동 + 샘플 CR reconcile 로그 채집)

### Step 2 진입 준비 (최소 체크리스트)
- [ ] kube-slint GitHub raw URL 접근 가능 여부 확인
- [ ] RBAC 통합 범위 설계 (ClusterRole 추가 vs 기존 manager-role 확장)
- [ ] Tiltfile 내 kube-slint 실행 로컬 리소스 추가
- 컨트롤러 로그에서 reconcile 이벤트 확인.
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
