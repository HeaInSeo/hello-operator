# PROGRESS_LOG

## [Technical Baseline]
- 아키텍처: Remote-first 개발 (Kind on Remote Dev Host)
- 빌드/배포: `ko` 기반 이미지 빌드 + `Tilt` 오케스트레이션
- 검증: `kube-slint` 원격 참조(예: GitHub raw URL) 기반 Shift-left SLI 계측을 CI/inner-loop에 조기 통합

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
- 목표: Step 1 실행 계획 확정 및 준비 상태 점검
- 체크리스트:
  - [x] 저장소 구조 및 실행 진입점(Tilt/ko/Kind/Make) 스캔
  - [x] PROGRESS_LOG 초기 구조 생성
  - [x] Technical Baseline 보강
  - [x] Step 1 구체 실행 계획 수립
  - [ ] Step 1 실제 실행(환경 기동/스모크)

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
