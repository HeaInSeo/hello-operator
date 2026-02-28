# PROGRESS_LOG

## [Technical Baseline]
- 아키텍처: Remote-first 개발 (Kind on Remote Host)
- 빌드/배포: `ko` 기반 이미지 빌드 + `Tilt` 오케스트레이션
- 검증: `kube-slint` 원격 참조(예: GitHub raw URL) 기반 Shift-left SLI 계측을 CI/inner-loop에 조기 통합
- SSH 포트 포워딩 기준:
  - Tilt UI: `localhost:10350 -> remote:10350`
  - Metrics(HTTP): `localhost:8080 -> remote:8080` (옵션, `--metrics-secure=false`일 때)
  - Metrics/Health 기본 포트: `localhost:8081 -> remote:8081` (health probe), `localhost:8443 -> remote:8443` (secure metrics)
  - Webhook: `localhost:9443 -> remote:9443` (webhook 활성화 시)

### 현재 저장소 기반 보강
- Kubebuilder 스캐폴드 구조 확인: `api/v1alpha1`, `internal/controller`, `config/*`, `test/e2e`.
- `Tiltfile`:
  - `allow_k8s_contexts('kind-tilt-study')`로 오배포 방지.
  - `k8s_yaml(kustomize('config/overlays/kind'))`로 kind 오버레이 배포.
  - `custom_build('controller', "ko build ./cmd > .tilt-ko-image-ref")` 패턴으로 ko 산출 이미지 ref 자동 치환.
  - `apply-sample`/`delete-sample` 로컬 리소스 제공.
- `hack/kind-init.sh`:
  - `KO_DOCKER_REPO=kind.local`, `KIND_CLUSTER_NAME=tilt-study`, `KUBECONTEXT=kind-tilt-study`를 source 방식으로 로드.
- `config/overlays`:
  - `kind`: `imagePullPolicy: IfNotPresent`, replicas 1.
  - `vm`: 매니저 리소스 requests/limits 강화(500m/512Mi, 2CPU/2Gi).
- `config/default`/`config/rbac`:
  - metrics endpoint 보호용 authn/authz RBAC(`metrics_auth_role`, `metrics_reader_role`) 포함.
  - Prometheus 관련 리소스는 기본 비활성(주석) 상태.
- `Makefile`:
  - `make test`(envtest 기반), `make test-e2e`(Kind 기반), `make lint`, `make deploy/undeploy` 제공.

### 현재 갭
- `kube-slint` 원격 리소스 참조 및 실행 루틴은 아직 저장소에 통합되지 않음.
- Tilt inner-loop 내 SLI 자동 체크 파이프라인은 아직 미구현.

## [Roadmap]
- Step 1: 현재 리포지토리의 Tilt/ko/Kind 환경 통합 및 스모크 테스트
- Step 2: kube-slint 원격 리소스(GitHub) 참조 및 RBAC 설정 통합
- Step 3: Tiltfile 고도화 (Inner-loop 내 SLI 자동 체크 기능 추가)
- Step 4: 환경별 Kustomize 오버레이(kind/vm) 정교화 및 배포 검증

## [Current Task]
- 목표: Step 1 실제 실행(환경 통합/스모크) 및 블로커 식별
- 체크리스트:
  - [x] 저장소 구조 및 실행 진입점(Tilt/ko/Kind/Make) 재스캔
  - [x] 원격 도구 가용성 점검(`kind`, `tilt`, `ko`, `kubectl`)
  - [x] Kubernetes 컨텍스트 점검(`kind-tilt-study` 존재 여부 포함)
  - [x] Kind 클러스터 생성 시도
  - [x] `tilt up` 실행 가능 여부 점검
  - [ ] Step 1 완전 성공(tilt 기반 기동 + 샘플 CR reconcile 로그 채집)

### Step 1 실행 계획 (제안)
1. 사전 도구/컨텍스트 검증
- `kind get clusters`, `kubectl config get-contexts`, `tilt version`, `ko version` 확인.
- `tilt-study` 클러스터/`kind-tilt-study` 컨텍스트 부재 시 생성 또는 정합화.

2. Kind/환경 변수 정합화
- 필요 시 `kind create cluster --name tilt-study`.
- `source hack/kind-init.sh` 후 `KO_DOCKER_REPO`, `KUBECONTEXT` 확인.

3. Tilt 기반 배포 스모크
- `tilt up`으로 `config/overlays/kind` 배포 + `ko build` 동작 확인.
- `.tilt-ko-image-ref` 생성 및 컨트롤러 파드 Ready 확인.

4. 기능 스모크
- `tilt trigger apply-sample` 또는 `kubectl apply -f config/samples/demo_v1alpha1_hello.yaml`.
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
