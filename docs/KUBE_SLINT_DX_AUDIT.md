# KUBE_SLINT_DX_AUDIT: hello-operator 개발자 관점 개발자 경험(DX) 평가

## 1. 감사 목적

이 문서는 `hello-operator` 개발자가 `kube-slint`를 inner-loop 개발 환경에
통합하려 할 때 경험하는 마찰(friction)을 측정하고 기록한 것이다.

감사 기준:
- **설치 경험**: 의존성 추가 및 빌드 성공 여부
- **API 사용성**: 코드 작성에 필요한 지식의 양과 복잡도
- **통합 복잡도**: 실제 Kubernetes 환경과 연결하기 위해 필요한 사전 작업 수
- **문서 품질**: 공식 README와 설계 원칙 문서의 충분성
- **피드백 품질**: 오류 메시지, 경고, 출력 결과의 명확성

감사 일자: 2026-03-02
감사 대상 버전: `github.com/HeaInSeo/kube-slint v1.0.0-rc.1`
감사 환경: `hello-operator` (Go 1.24.6, controller-runtime v0.22.4, kind-tilt-study 클러스터)

---

## 2. kube-slint 개요

`kube-slint`는 Kubernetes 오퍼레이터의 Operational SLI(서비스 수준 지표)를
측정하는 Go 라이브러리 및 E2E 테스트 하네스 프레임워크다.

### 핵심 설계 원칙 (sli-design-principles.md 기준)

- **비침투적(Non-invasive)**: 오퍼레이터 코드를 수정하지 않는다. Reconcile 로직에
  계측 코드를 삽입하지 않는다.
- **외부 측정(External measurement)**: 오퍼레이터의 `/metrics` 엔드포인트를 외부에서
  스크랩하여 SLI를 계산한다.
- **안전 우선(Safety-first)**: 계측 실패가 테스트 실패로 이어지지 않는다. 스크랩
  오류나 파싱 오류는 SLI 항목을 skip으로 처리한다.
- **아티팩트 생성**: 각 측정 세션은 JSON 요약 파일(`sli-summary.<runID>.<testCase>.json`)을
  생성한다.

### 아키텍처 구성

```
test/e2e/harness/         ← 통합 E2E 테스트 하네스 (주 진입점)
  session.go              ← SessionConfig, NewSession, Start, End
  presets.go              ← DefaultV3Specs (controller-runtime 기본 SLI 목록)
  discovery.go            ← .slint.yaml / slint.config.yaml 자동 탐색
  fetcher_curlpod.go      ← curl 파드 기반 메트릭 수집기
  sweep.go                ← 테스트 후 리소스 정리

pkg/slo/
  spec/spec.go            ← SLISpec, MetricRef, ComputeSpec, Rule 타입 정의
  engine/engine.go        ← 측정 계산 엔진
  fetch/fetcher.go        ← MetricsFetcher 인터페이스
  summary/schema.go       ← JSON 요약 스키마
```

---

## 3. 설치 경험 평가

### 3.1 go get 명령 실행

```bash
go get github.com/HeaInSeo/kube-slint@latest
```

**결과**:
```
go: downloading github.com/HeaInSeo/kube-slint v1.0.0-rc.1
go: added github.com/HeaInSeo/kube-slint v1.0.0-rc.1
```

**평가: 양호**

- 명령 한 줄로 설치 완료.
- `v1.0.0-rc.1` 태그가 `latest`로 해결됨.
- 빌드 후 go.sum이 정상 업데이트됨.

**주의사항**:

- `rc.1`은 Release Candidate이며 아직 stable 릴리스가 아님. 프로덕션 CI 파이프라인에
  고정 버전 핀닝(예: `@v1.0.0-rc.1`) 필요.
- `go get` 후 golang.org/x/* 의존성들이 업그레이드됨 (net, sync, sys 등).
  기존 hello-operator 의존성과 버전 충돌 가능성은 없었으나, 메이저 프로젝트에서는
  별도 모듈이나 `replace` 지시문으로 격리 권장.

### 3.2 import 경로

```go
// E2E 테스트 파일에서 사용
import (
    "github.com/HeaInSeo/kube-slint/test/e2e/harness"
    "github.com/HeaInSeo/kube-slint/pkg/slo/spec"
)
```

**평가: 양호** — import 경로가 직관적이며 패키지 구조가 명확히 분리되어 있음.

---

## 4. API 사용성 평가

### 4.1 기본 통합 흐름

`hello-operator` E2E 테스트에서 kube-slint를 사용하는 최소 코드는 다음과 같다.

```go
// 예: test/e2e/sli_test.go (hello-operator 프로젝트에 추가할 파일)
package e2e_test

import (
    "context"
    "testing"

    "github.com/HeaInSeo/kube-slint/test/e2e/harness"
)

func TestHelloOperatorSLI(t *testing.T) {
    session := harness.NewSession(harness.SessionConfig{
        Namespace:          "hello-operator-system",
        MetricsServiceName: "hello-operator-controller-manager-metrics-service",
        TestCase:           "hello-sample-create",
        Suite:              "hello-operator",
        ArtifactsDir:       "/tmp/sli-artifacts",
    })

    session.Start()

    // 테스트 워크로드 실행 (CR 생성, 조정 완료 대기 등)
    // ... kubectl apply -f config/samples/demo_v1alpha1_hello.yaml ...

    ctx := context.Background()
    summary, err := session.End(ctx)
    if err != nil {
        t.Logf("SLI evaluation warning: %v", err)
    }
    if summary != nil {
        t.Logf("SLI summary: %+v", summary)
    }

    defer session.Cleanup(ctx)
}
```

**평가: 양호** — `NewSession → Start → End` 3단계 패턴이 명확하고 직관적.

### 4.2 DefaultV3Specs (기본 SLI 항목)

`presets.go`의 `DefaultV3Specs()`가 자동으로 적용하는 controller-runtime SLI 목록:

| SLI ID | 메트릭 | 계산 방식 | hello-operator 적용성 |
|--------|--------|-----------|----------------------|
| `reconcile_total_delta` | `controller_runtime_reconcile_total` | Delta | 직접 적용 가능 |
| `reconcile_success_delta` | `controller_runtime_reconcile_total{result="success"}` | Delta | 직접 적용 가능 |
| `reconcile_error_delta` | `controller_runtime_reconcile_total{result="error"}` | Delta | 직접 적용 가능 |
| `workqueue_adds_total_delta` | `workqueue_adds_total` | Delta | 직접 적용 가능 |
| `workqueue_retries_total_delta` | `workqueue_retries_total` | Delta | 직접 적용 가능 |
| `workqueue_depth_end` | `workqueue_depth` | Single(start) | 직접 적용 가능 |
| `rest_client_requests_total_delta` | `rest_client_requests_total` | Delta | 직접 적용 가능 |
| `rest_client_429_delta` | `rest_client_requests_total{code="429"}` | Delta | API 서버 병목 감지 |
| `rest_client_5xx_delta` | `rest_client_requests_total{code="5xx"}` | Delta | 5xx 오류 감지 |

**평가: 매우 양호** — hello-operator가 사용하는 controller-runtime v0.22.4 메트릭과
그대로 호환된다. 추가 코드 없이 기본 프리셋만으로 유의미한 SLI를 수집할 수 있다.

### 4.3 커스텀 SLI 정의

기본 프리셋 외에 커스텀 SLI를 정의하는 방법:

```go
customSpecs := []spec.SLISpec{
    {
        ID:    "hello_reconcile_error_rate",
        Title: "Hello reconcile error rate",
        Unit:  "count",
        Kind:  "delta_counter",
        Inputs: []spec.MetricRef{
            spec.PromMetric("controller_runtime_reconcile_total",
                spec.Labels{"controller": "hello", "result": "error"}),
        },
        Compute: spec.ComputeSpec{Mode: spec.ComputeDelta},
        Judge: &spec.JudgeSpec{
            Rules: []spec.Rule{
                {Op: spec.OpGT, Target: 0, Level: spec.LevelFail},
            },
        },
    },
}

session := harness.NewSession(harness.SessionConfig{
    // ...
    Specs: customSpecs,
})
```

**평가: 양호** — `SLISpec` 구조체 필드명이 직관적이며 `Judge.Rules`로 임계값 설정이 가능.

### 4.4 설정 파일 자동 탐색 (discovery)

kube-slint는 `SLINT_CONFIG_PATH` 환경 변수 또는 `.slint.yaml`/`slint.config.yaml`
파일을 자동으로 탐색한다.

```yaml
# .slint.yaml (hello-operator 루트에 배치 시 자동 적용)
format: v1
strictness:
  mode: BestEffort          # BestEffort | StrictCollection | StrictEvaluation
  thresholds:
    maxStartSkewMs: 500
    maxEndSkewMs: 500
gating:
  gateOnLevel: fail         # none | warn | fail
cleanup:
  enabled: true
  mode: on-success          # always | on-success | on-failure | manual
write:
  artifactsDir: /tmp/sli-artifacts
```

**평가: 양호** — 설정을 코드 밖으로 분리할 수 있어 테스트 코드 간결성이 유지됨.

---

## 5. 통합 복잡도 평가

### 5.1 기본 메트릭 수집: curlpod 방식

kube-slint의 기본 Fetcher는 `curlimages/curl:latest` 이미지로 임시 파드를 실행하여
오퍼레이터의 HTTPS 메트릭 엔드포인트(`:8443/metrics`)에 접근한다.

```
curlpod (curlimages/curl:latest)
  → HTTPS://hello-operator-controller-manager-metrics-service.hello-operator-system.svc:8443/metrics
  → 메트릭 텍스트 파싱
  → SLI 계산
```

**마찰 포인트 1: curlimages/curl:latest 이미지 Pull**

- kind 클러스터에서 외부 레지스트리(Docker Hub)에서 이미지를 pull해야 함.
- ttl.sh 레지스트리는 정상 동작하나, Docker Hub에서 `curlimages/curl` pull 시
  rate limit 가능성 있음.
- 해결: `SessionConfig` 내 `CurlImage` 필드로 사설 미러로 대체 가능하나, 이 필드는
  `sessionImpl` 내부에 있어 `SessionConfig`를 통해 직접 설정할 수 없음 (v1.0.0-rc.1 기준).

**마찰 포인트 2: RBAC 설정 필요**

curlpod가 `/metrics` 엔드포인트에 접근하려면 ServiceAccount 토큰이 필요하다.

hello-operator의 기존 `config/rbac/metrics_auth_role.yaml`에 MetricsReader ClusterRole이
이미 존재하지만, curlpod용 ServiceAccount와 바인딩을 추가해야 한다.

필요한 RBAC 추가:
```yaml
# config/rbac/sli-reader-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sli-checker
  namespace: hello-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sli-checker-metrics-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hello-operator-metrics-reader
subjects:
- kind: ServiceAccount
  name: sli-checker
  namespace: hello-operator-system
```

그런 다음 E2E 테스트에서 토큰 획득:
```go
token, err := kubeutil.GetServiceAccountToken(ctx, client, "hello-operator-system", "sli-checker")
// ...
session := harness.NewSession(harness.SessionConfig{
    ServiceAccountName: "sli-checker",
    Token:              token,
    // ...
})
```

**마찰 포인트 3: HTTPS 자체 서명 인증서**

컨트롤러 메트릭 서버는 controller-runtime이 생성한 자체 서명 TLS 인증서를 사용한다.
curlpod는 기본적으로 인증서 검증을 수행하므로, InsecureSkipVerify 설정이 필요하다.
현재 `SessionConfig`에 TLS 검증 건너뛰기 옵션이 노출되어 있지 않다 (v1.0.0-rc.1 기준).

### 5.2 Mock Fetcher를 사용한 단위 테스트 (권장)

실제 K8s 클러스터 없이도 harness 통합 테스트가 가능하다.

```go
// httptest.Server를 Fetcher에 주입하는 방식 (harness_integration_test.go 참고)
type mockFetcher struct {
    server *httptest.Server
}

func (f *mockFetcher) Fetch(ctx context.Context, at time.Time) (fetch.Sample, error) {
    resp, _ := http.Get(f.server.URL)
    body, _ := io.ReadAll(resp.Body)
    values, _ := parsePrometheus(body)
    return fetch.Sample{At: at, Values: values}, nil
}
```

**평가: 양호** — 클러스터 의존 없이 핵심 비즈니스 로직(계산, 판단, 요약 생성)을
검증할 수 있다. 로컬 개발 루프에서 빠른 피드백이 가능하다.

---

## 6. 문서 품질 평가

### 6.1 README.md (영문 / 한국어)

| 항목 | 평가 |
|------|------|
| 아키텍처 개요 | 양호 - 전환(Standalone → Library) 배경 설명 포함 |
| 설치 방법 | 양호 - `go get` 명령 제공 |
| 기본 통합 예시 | 미흡 - `SessionConfig` 필드별 설명이 코드 주석에만 존재 |
| Kustomize 스택 연동 | 양호 - 원격 리소스 핀닝(태그/SHA) 주의사항 명시 |
| Tiltfile 연동 | 없음 - inner-loop 개발자를 위한 Tilt 통합 예시 미제공 |
| 문제 해결 가이드 | 없음 - 일반적인 오류 사례 및 해결책 미제공 |

### 6.2 sli-design-principles.md

**평가: 우수** — 프레임워크의 철학(비침투, 안전 우선, 외부 측정)이 명확히 서술되어 있다.
설계 결정 이유를 이해하는 데 필수적인 문서다.

### 6.3 test/e2e/README.md

**평가: 양호** — Mock 기반 단위 테스트 철학과 실행 방법이 잘 설명되어 있다.

---

## 7. 갭 분석 (Gap Analysis)

### 7.1 [높음] curlpod CurlImage 커스터마이징 불가 (v1.0.0-rc.1)

- **현상**: `sessionImpl.CurlImage`는 `"curlimages/curl:latest"`로 고정되어 있으나,
  이 필드가 `SessionConfig`에 노출되어 있지 않아 사용자가 변경할 수 없다.
- **영향**: kind 환경에서 Docker Hub rate limit 발생 시 curlpod 시작 실패.
  사설 미러나 ttl.sh에 캐시된 이미지를 사용하려면 커스텀 Fetcher 구현 필요.
- **임시 해결**: `SessionConfig.Fetcher`에 직접 커스텀 Fetcher를 주입하거나,
  Mock Fetcher로 단위 테스트 수행.

### 7.2 [높음] HTTPS TLS 검증 건너뛰기 옵션 없음 (v1.0.0-rc.1)

- **현상**: controller-runtime 메트릭 서버는 자체 서명 인증서를 사용하나,
  curlpod는 인증서 검증 실패로 접속 거부될 수 있다.
- **영향**: 기본 SessionConfig로는 hello-operator 메트릭을 수집할 수 없음.
  curlpod의 `curl` 명령에 `-k` 플래그가 필요하나 현재 노출되지 않음.
- **임시 해결**: 커스텀 Fetcher를 작성하여 `http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}`로
  직접 메트릭을 수집.

### 7.3 [중간] RBAC 및 ServiceAccount 설정 예시 미제공

- **현상**: SessionConfig에 `ServiceAccountName`과 `Token` 필드가 있으나,
  이를 위한 RBAC 설정(ServiceAccount + ClusterRoleBinding) 예시가 문서에 없음.
- **영향**: RBAC 설정 없이는 기본 curlpod Fetcher가 401/403으로 실패.
- **권장 해결**: hello-operator 레포에 `config/rbac/sli-reader.yaml` 추가 필요.
  kube-slint 문서에 표준 RBAC 템플릿 제공 권장.

### 7.4 [중간] Tiltfile inner-loop 연동 예시 없음

- **현상**: Tilt `local_resource`와 kube-slint 세션을 연동하는 예시가 문서에 없음.
- **영향**: 개발자가 `tilt up` 중 SLI를 실시간으로 확인하려면 직접 통합 코드 작성 필요.
- **권장 해결**: Tiltfile에 아래 패턴 추가:
  ```python
  local_resource(
    'sli-check',
    cmd='go test ./test/e2e/ -run TestHelloOperatorSLI -v -timeout 2m',
    auto_init=False,
    deps=['test/e2e/', 'config/samples/'],
  )
  ```

### 7.5 [낮음] rc.1 릴리스 안정성

- **현상**: 현재 최신 버전이 `v1.0.0-rc.1`(Release Candidate).
- **영향**: API 호환성이 stable 릴리스까지 보장되지 않을 수 있음.
- **권장 해결**: CI 파이프라인에서는 버전을 명시적으로 고정(`@v1.0.0-rc.1`).
  Stable 릴리스 후 의존성 업데이트 계획 수립.

---

## 8. 통합 계획 (권장 순서)

hello-operator에 kube-slint를 통합하기 위한 단계별 계획:

### Phase 1: Mock 기반 단위 테스트 (클러스터 불필요)

1. `test/e2e/sli_integration_test.go` 작성
2. `httptest.Server`로 가상 `/metrics` 응답 주입
3. `harness.NewSession(SessionConfig{Fetcher: mockFetcher})` 패턴 사용
4. `go test ./test/e2e/ -run TestSLI -v` 로 검증

**예상 소요**: 2-3시간. 클러스터 없이 로컬에서 완료 가능.

### Phase 2: RBAC 설정 + curlpod 연동

1. `config/rbac/sli-reader.yaml` 작성 (ServiceAccount + ClusterRoleBinding)
2. `config/overlays/kind/kustomization.yaml`에 sli-reader.yaml 추가
3. `tilt ci` 재실행 후 RBAC 반영 확인
4. E2E 테스트에서 실제 curlpod Fetcher로 메트릭 수집 시도

**예상 소요**: 2-4시간. HTTPS 인증서 문제 해결이 가장 큰 변수.

### Phase 3: Tiltfile local_resource 연동

1. Tiltfile에 `sli-check` local_resource 추가
2. 샘플 CR apply/delete 버튼과 연동하여 SLI 자동 수집
3. JSON 아티팩트를 `/tmp/sli-artifacts/`에 저장

**예상 소요**: 1-2시간.

---

## 9. 결론

`kube-slint v1.0.0-rc.1`은 hello-operator와 같은 controller-runtime 기반 오퍼레이터에
즉시 적용 가능한 SLI 측정 프레임워크다.

**강점**:
- 오퍼레이터 코드 수정 불필요 (비침투적 설계)
- controller-runtime 메트릭 기본 프리셋 제공 (9개 SLI)
- Mock Fetcher로 클러스터 없는 단위 테스트 가능
- `.slint.yaml` 설정 파일 자동 탐색으로 코드 외 설정 관리 가능

**주요 해결 과제**:
- curlpod TLS 인증서 검증 우회 방법 확보 (커스텀 Fetcher 필요)
- RBAC 설정 예시 문서화 (hello-operator 레포 기여 필요)
- Tiltfile 연동 패턴 문서화

**종합 평가**: Phase 1(Mock 기반 단위 테스트)은 즉시 착수 가능하며, Phase 2-3(실 클러스터
연동)은 HTTPS 및 RBAC 설정 문제 해결 후 진행을 권장한다.

---

## [Update 2026-03-02] kube-slint main 브랜치 변경 사항

> 이 섹션은 이전 감사(v1.0.0-rc.1)에서 발견한 갭이 kube-slint 업데이트로
> 해소되었는지 추적한다. 기존 내용은 유지하고 이어 붙이는 방식으로 관리한다.

### 감사 기준 버전

- 감사 기준: `v1.0.0-rc.1` (2026-03-02 최초 감사)
- 이번 업데이트: commit `58c0d88` (`feat(harness): Add SessionConfig knobs for TLS and curl image overrides`)
- go.mod 반영 버전: `v1.0.0-rc.1.0.20260302080738-58c0d8811314`

### 갭 해소 현황

#### [해소됨] 갭 7.1: CurlImage 커스터마이징 불가

**이전 상태** (v1.0.0-rc.1):
`sessionImpl.CurlImage`가 `SessionConfig`에 노출되지 않아 사용자가 변경 불가.

**현재 상태** (58c0d88):
`SessionConfig`에 `CurlImage string` 필드 추가됨.

```go
// 이제 SessionConfig에서 직접 설정 가능
session := harness.NewSession(harness.SessionConfig{
    CurlImage: "ttl.sh/curlimages-curl:latest", // Docker Hub 대신 캐시 이미지 사용
    // ...
})
```

kind 환경에서 Docker Hub rate limit 우려 없이 사설 미러 또는 ttl.sh에 캐시된 이미지를
사용할 수 있게 되었다.

#### [해소됨] 갭 7.2: HTTPS TLS 검증 건너뛰기 옵션 없음

**이전 상태** (v1.0.0-rc.1):
curlpod Fetcher가 자체 서명 인증서를 가진 메트릭 엔드포인트에 접근 시 TLS 검증 실패.

**현재 상태** (58c0d88):
`SessionConfig`에 `TLSInsecureSkipVerify bool` 필드 추가됨.
curlpod 실행 시 `-k` 플래그가 자동으로 추가된다.

```go
// controller-runtime의 자체 서명 인증서 우회
session := harness.NewSession(harness.SessionConfig{
    TLSInsecureSkipVerify: true,
    // ...
})
```

이로써 Phase 2(curlpod Fetcher + 실 클러스터 연동)의 가장 큰 기술적 장벽이 해소되었다.

### 잔존 갭

#### [미해소] 갭 7.3: RBAC 및 ServiceAccount 설정 예시 미제공

상태 변화 없음. hello-operator에 RBAC 설정을 직접 추가해야 한다.

```yaml
# 추가 필요: config/rbac/sli-reader.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sli-checker
  namespace: hello-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sli-checker-metrics-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: hello-operator-metrics-reader
subjects:
- kind: ServiceAccount
  name: sli-checker
  namespace: hello-operator-system
```

#### [신규 발견] 갭 N1: SLI 스펙 라벨 필터와 실제 메트릭 라벨 불일치

**발견 경위**: Phase 1 Mock 테스트(`test/e2e/sli_integration_test.go`) 실행 중 발견.

**현상**:
`DefaultV3Specs()`의 `reconcile_success_delta`는 아래 키를 조회한다:
```
controller_runtime_reconcile_total{result="success"}
```

하지만 controller-runtime이 실제로 노출하는 메트릭은:
```
controller_runtime_reconcile_total{controller="hello",result="success"}
```

라벨 집합이 다르므로 `promkey.Canonicalize`가 서로 다른 키를 생성하여 일치하지 않는다.
결과적으로 `reconcile_success_delta`는 `status=skip`으로 처리된다.

**실측 결과**:
```
reconcile_total_delta    status=pass   value=3   (레이블 없는 합산 키 → 정상)
reconcile_success_delta  status=skip   value=nil (레이블 불일치 → 건너뜀)
reconcile_error_delta    status=skip   value=nil (레이블 불일치 → 건너뜀)
```

**해결 방안**:
커스텀 SLI 스펙 정의 시 `controller` 라벨을 명시하거나, `reconcile_total_delta`(레이블
없는 합산)를 주 지표로 사용한다.

```go
// 권장: controller 라벨 포함하여 정확히 일치
spec.PromMetric("controller_runtime_reconcile_total",
    spec.Labels{"controller": "hello", "result": "success"}),
```

#### [신규 발견] 갭 N2: Tiltfile 연동 예시 미제공 (unchanged)

상태 변화 없음. hello-operator Tiltfile에 직접 추가 필요 (현재 `sli-mock-test` 추가 완료).

### Phase 1 완료 요약 (2026-03-02)

`test/e2e/sli_integration_test.go` 구현 완료.

- 클러스터 불필요: `httptest.Server` 2개(baseline, after-reconcile)로 메트릭 시뮬레이션
- `reconcile_total_delta = 3` 검증 통과 (start=0→end=3)
- Tiltfile `sli-mock-test` local_resource 추가: `go test ./test/e2e/ -run TestHelloSLIMock`
- 실행 결과: `ok 0.10s` (PASS)

### Phase 2 준비 상태

갭 7.1(CurlImage)과 7.2(TLS)가 해소되어 Phase 2 착수 조건이 충족되었다.
남은 작업: RBAC 설정 추가(`config/rbac/sli-reader.yaml`) + 실 클러스터에서 curlpod 검증.

---

## [Update 2026-03-03] 회귀 탐지 강화를 위한 추가 갭 분석

> 이 섹션은 "코드 수정 시 SLI 지표가 회귀하는지 자동으로 탐지하기 위해 kube-slint에서
> 구현이 필요한 지점"을 조사한 결과다.
> JSON 아티팩트 저장 경로 확인 과정에서 파생된 분석이다.

### 배경

`session.End()` 반환값(`Summary`)이 JSON 파일로 저장되려면 `SessionConfig.ArtifactsDir`가
비어있지 않아야 한다 (`session.go:ShouldWriteArtifacts()`). 이 조건을 확인하는 과정에서
회귀 방어선 전체가 비활성 상태임을 발견했다.

### 신규 갭 목록

#### [갭 A] reconcile_error_delta JudgeSpec 규칙 주석 처리

**파일**: `test/e2e/harness/presets.go:52`
**심각도**: 높음

```go
// 현재 상태 (비활성)
// Judge: &spec.JudgeSpec{Rules: []spec.Rule{{Op: spec.OpGT, Target: 0, Level: spec.LevelFail}}},
```

에러 delta가 0 초과여도 `reconcile_error_delta`의 status가 `"pass"`로 출력된다.
오퍼레이터 코드에서 에러를 유발하는 회귀가 발생해도 테스트가 통과한다.

**필요 조치**: 주석 해제 (kube-slint presets.go 한 줄 수정).

단, 갭 B(레이블 불일치)가 해소되지 않으면 이 규칙이 발동하더라도 `"skip"`으로 처리되어
실질적 효과가 없다. 갭 A와 갭 B는 함께 해결해야 한다.

#### [갭 B] 레이블 부분 일치(partial label match) 미지원 - 기존 갭 N1 보완

**파일**: `pkg/slo/engine/engine.go` (입력 조회 로직), `test/e2e/harness/presets.go:37~49`
**심각도**: 높음 (갭 A 효과를 무력화)

이전 감사(갭 N1)에서 발견한 내용의 엔진 레벨 원인 분석:

- spec 조회 키: `controller_runtime_reconcile_total{result="success"}`
- 실제 메트릭 키: `controller_runtime_reconcile_total{controller="hello",result="success"}`
- 엔진이 exact key match를 수행하므로 레이블 집합이 다르면 `"skip"` 처리

결과적으로 `reconcile_success_delta`와 `reconcile_error_delta`가 항상 `"skip"`된다.

**필요 조치 (선택지)**:
1. **단기**: presets.go의 spec 입력을 `{controller="hello", result="success"}` 형태의 full label로 교체.
   단, controller 이름이 오퍼레이터마다 달라 범용 프리셋으로 부적합.
2. **중기 (권장)**: 엔진의 metric lookup에 레이블 서브셋 매칭 지원.
   spec에 `{result="success"}` 지정 시 `result="success"`를 포함하는 모든 시리즈를 합산.

#### [갭 C] workqueue_depth_end ComputeMode 불일치

**파일**: `test/e2e/harness/presets.go:89`
**심각도**: 낮음

```go
Compute: spec.ComputeSpec{Mode: spec.ComputeSingle}, // 시작 스냅샷
// 코드 주석: "v4에서는 end-only gauge 권장"
```

gauge 타입인 `workqueue_depth`는 측정 창이 닫히는 시점(End)의 값이 의미 있다.
"테스트 종료 후 큐가 비었는가?"를 확인해야 하는데 시작 시점 값을 본다.

**필요 조치**: `ComputeEnd` 모드를 `pkg/slo/engine/engine.go`에 구현 후 프리셋 교체.

#### [갭 D] cross-run 회귀 탐지(baseline 비교) 부재

**심각도**: 중간 (절대값 게이팅으로 부분 대체 가능)

kube-slint는 단일 실행의 절대값 게이팅만 지원한다.
"이전 실행 대비 수치가 나빠졌는가?"를 판단하는 기능이 없다.

`Summary` 구조체에는 비교를 위한 기반 필드가 있다:
- `Config.RunID` - 실행 고유 ID
- `Config.Tags` - 임의 메타데이터 (git_commit, branch 등 삽입 가능)
- `Results[].Value` - 수치 결과

**필요 조치 (신규 기능)**:

```
pkg/slo/regression/comparator.go (신규)
  - LoadBaseline(path string) (*Summary, error)
  - Compare(baseline, current *Summary, tolerance float64) (*RegressionReport, error)
  - RegressionReport.HasRegression() bool
```

**사용 패턴**:
1. 첫 실행 후 JSON을 `testdata/sli-baseline.json`으로 커밋
2. 이후 실행마다 현재 JSON과 baseline을 Compare() 호출
3. 허용 범위 초과 시 테스트 실패

#### [갭 E] GateOnLevel 기본값 "none" (hello-operator 설정 문제)

**파일**: `test/e2e/harness/propagation.go:110`
**심각도**: 높음 (갭 A가 활성화되어도 테스트 실패로 전파 안 됨)

```go
if gateOnLevel == "" || gateOnLevel == "none" {
    return nil // 게이팅 없음
}
```

`SessionConfig.GateOnLevel`을 설정하지 않으면 Judge 규칙이 `"fail"`을 마킹해도
`session.End()`가 에러를 반환하지 않는다.

이것은 kube-slint 코드 수정이 아닌 **hello-operator 테스트 설정 문제**이나,
`.slint.yaml` discovery를 통한 기본값 제공을 kube-slint 측에서 고려할 수 있다.

**즉각 해결 가능**: hello-operator SessionConfig에 `GateOnLevel: "fail"` 추가.

### 갭 우선순위 요약

| 갭 | 위치 | 난이도 | 효과 |
|----|------|--------|------|
| A: Judge 주석 해제 | kube-slint presets.go | 한 줄 | 에러 delta 마킹 활성화 |
| E: GateOnLevel 설정 | hello-operator SessionConfig | 한 줄 | 테스트 실패 전파 |
| B: 레이블 부분 일치 | kube-slint engine | 중간 | A/E의 실질적 효과 확보 |
| C: ComputeEnd 구현 | kube-slint engine | 중간 | gauge 정확도 개선 |
| D: cross-run 비교 | kube-slint 신규 패키지 | 높음 | 추세 기반 회귀 탐지 |

**갭 A + E는 코드 한 줄씩으로 즉시 해결 가능하나, 갭 B가 없으면 A의 효과가 없다.
실질적인 첫 번째 회귀 방어선은 갭 A + B + E를 묶어서 해결하는 것이다.**

### 2026-03-03 완료 사항

- `test/e2e/sli_integration_test.go`: `ArtifactsDir: "/tmp/sli-results"` 추가
- `test/e2e/sli_e2e_test.go`: `ArtifactsDir: "/tmp/sli-results"` 추가
- 저장 경로: `/tmp/sli-results/sli-summary.hello-operator-sli.hello-sample-create.json`

---

## [Update 2026-03-04] Phase 3 실 클러스터 E2E 검증 중 발견된 갭

> Phase 3 (`E2E_SLI=1 go test ./test/e2e/ -run TestHelloSLIE2E`) 실행 과정에서
> kind-tilt-study 클러스터에서 두 가지 구조적 갭과 스크립트 버그를 추가로 발견했다.

### 환경

- 클러스터: kind-tilt-study (kind v0.24.0, k8s v1.31.0, rootful podman)
- kube-slint: `v1.0.0-rc.1.0.20260302080738-58c0d8811314`
- 테스트 결과: PASS 달성 (workaround 적용 후)

---

### [갭 F] curlpod imagePullPolicy 미설정 - kind 환경 ImagePullBackOff 유발

**심각도**: 높음 (air-gapped / 인터넷 미연결 kind 환경에서 완전 차단)
**파일**: `pkg/slo/fetch/curlpod/client.go` (RunOnce 함수)

**현상**:

curlpod 스펙(`kubectl run` 명령의 `--overrides` JSON)에 `imagePullPolicy`가 명시되지 않음.
Kubernetes 기본값 적용 규칙:
- 태그가 `latest`이거나 없을 경우 → `Always` (항상 레지스트리에서 pull 시도)
- 태그가 구체적인 버전 태그일 경우 → `IfNotPresent` (로컬 캐시 우선)

기본 CurlImage는 `"curlimages/curl:latest"` (latest 태그) → `imagePullPolicy: Always`.
kind-tilt-study 클러스터의 노드는 docker.io에 접근 불가 (`no route to host`).
결과: `ImagePullBackOff` → curlpod Fetch 실패.

**실측 증거**:
```
Warning  Failed   ...  Failed to pull image "curlimages/curl:latest":
  failed to do request: Head "https://registry-1.docker.io/v2/curlimages/curl/manifests/latest":
  dial tcp 44.217.10.11:443: connect: no route to host
```

**해결 방안**:

**(권장) kube-slint 수정**: `Client` 구조체에 `ImagePullPolicy string` 필드 추가.
`RunOnce()`의 파드 스펙에 `"imagePullPolicy": c.ImagePullPolicy` 삽입.
기본값을 `"IfNotPresent"`로 설정하여 air-gapped 환경에서도 동작하게 한다.

```go
// 제안: pkg/slo/fetch/curlpod/client.go
type Client struct {
    // ...기존 필드...
    ImagePullPolicy string // e.g. "IfNotPresent" | "Always" | "Never"
}

// New() 기본값
return &Client{
    // ...
    ImagePullPolicy: "IfNotPresent", // 기존 동작보다 안전한 기본값
}
```

**(현재 workaround)**: `SessionConfig.CurlImage`에 non-latest 태그를 지정한다.
```go
// "kind-cached" 태그 → imagePullPolicy: IfNotPresent (기본값)
// 단, 이미지를 미리 kind containerd에 로드해야 함
session := harness.NewSession(harness.SessionConfig{
    CurlImage: "curlimages/curl:kind-cached",
    // ...
})
```

이미지 사전 로드 절차:
```bash
# 호스트에서 pull 후 kind-cached 태그 부여 (non-latest)
podman tag curlimages/curl:latest curlimages/curl:kind-cached
podman save curlimages/curl:kind-cached -o /tmp/curl.tar
# kind 노드 containerd에 import (privileged pod 방식)
# → scripts/kind-image-load.sh 참조
```

---

### [갭 G] session.Start() 미스냅샷 - 엔진 설계와 curlpod fetcher 불일치

**심각도**: 높음 (curlpod fetcher 사용 시 delta 항상 0)
**파일**: `test/e2e/harness/session.go` (Start, End), `pkg/slo/engine/engine.go` (Execute)

**현상**:

`engine.Execute()`는 `End()` 내부에서 fetcher를 두 번 호출하여 delta를 계산한다:

```go
// engine.go
start, _ := e.fetcher.Fetch(ctx, cfg.StartedAt)   // 첫 번째 호출 (현재 상태)
end, _   := e.fetcher.Fetch(ctx, cfg.FinishedAt)   // 두 번째 호출 (현재 상태)
delta    := end.Values[key] - start.Values[key]
```

curlpod fetcher는 `at time.Time` 파라미터를 무시하고 항상 현재 상태를 반환한다:

```go
// fetcher_curlpod.go
func (f *curlPodFetcher) Fetch(_ context.Context, at time.Time) (fetch.Sample, error) {
    // at 파라미터 미사용 - 항상 현재 상태 반환
    raw, _ := f.pod.Run(podCtx, ...)
    return fetch.Sample{At: at, Values: values}, nil
}
```

`session.Start()`는 시작 시각만 기록하고 메트릭 스냅샷을 수집하지 않는다:

```go
// session.go
func (s *Session) Start() {
    s.impl.started = now()  // 시각만 기록, fetcher 호출 없음
}
```

결과:
1. `session.Start()` 호출 후 CR 적용 → Reconcile 완료 → 5초 대기
2. `session.End()` 호출 → engine이 `Start` fetch, `End` fetch를 순차 실행
3. 두 fetch 모두 CR 적용 후(post-reconcile) 상태를 반환
4. delta = post - post = 0

**실측 결과** (workaround 적용 전):
```
reconcile_total_delta  status=pass  value=0   ← 의도와 다름
```

**설계 불일치 원인**:

엔진 설계는 Prometheus range query처럼 임의 시각의 메트릭을 조회할 수 있는 fetcher를
가정한다. curlpod fetcher는 현재 상태만 반환하는 실시간 fetcher이므로, 엔진이 두 번
호출해도 서로 다른 과거 시점을 볼 수 없다.

**kube-slint 개선 제안**:

`session.Start()`가 curlpod fetcher의 경우 시작 스냅샷을 미리 수집하고 저장해야 한다.
이를 위해 fetcher가 "pre-fetch" 능력을 선언할 수 있는 인터페이스 분리가 필요하다:

```go
// 제안: pkg/slo/fetch/prefetcher.go
type PreFetchable interface {
    MetricsFetcher
    PreFetch(ctx context.Context) error  // Start() 시점에 스냅샷 저장
}

// session.go Start() 수정 제안
func (s *Session) Start() {
    s.impl.started = now()
    if pf, ok := s.impl.fetcher.(fetch.PreFetchable); ok {
        pf.PreFetch(ctx)  // curlpod fetcher가 이를 구현하면 start 스냅샷 저장
    }
}
```

**(현재 workaround)**: `snapshotFetcher` 패턴으로 before/after 스냅샷을 테스트에서
직접 수집하고 harness에 주입한다. `test/e2e/sli_e2e_test.go` 참조.

```go
// 테스트에서 직접 두 번 curlpod를 실행하여 스냅샷 수집
startValues, _ := fetchMetricsViaCurlpod(ctx, ...)   // CR 적용 전
kubectlApplySample(cr)
time.Sleep(5 * time.Second)
endValues, _ := fetchMetricsViaCurlpod(ctx, ...)     // CR 적용 후

// snapshotFetcher로 harness에 주입
session := harness.NewSession(harness.SessionConfig{
    Fetcher: &snapshotFetcher{startValues: startValues, endValues: endValues},
})
session.Start()
sum, _ := session.End(ctx)
// reconcile_total_delta = endValues - startValues = 정확한 delta
```

---

### [버그] scripts/kind-image-load.sh: awk/head 컨테이너 내부 실행

**심각도**: 중간 (kind-image-load.sh가 항상 exit code 127로 실패)
**파일**: `scripts/kind-image-load.sh`

**현상**:

스크립트의 이미지 ID 검색 로직이 `awk`와 `head`를 `kubectl exec` 내부(kube-proxy 컨테이너)
에서 실행한다. kube-proxy 컨테이너는 BusyBox 없이 최소화된 이미지로, 이 명령들이 없다.

```bash
# 문제 코드 (수정 전)
IMAGE_ID=$(kubectl exec -n kube-system $HELPER_POD -- sh -c \
  "ctr images list 2>&1 | grep -v 'registry.k8s.io' | awk '{print \$1}' | head -1")
# → sh: 1: awk: not found
# → sh: 1: head: not found
# → exit code 127
```

**수정**: ctr 출력을 호스트로 가져온 후 호스트에서 awk/head 처리.

```bash
# 수정 후: ctr 출력을 호스트로 전달
IMAGES_LIST=$(kubectl exec -n kube-system $HELPER_POD -- \
  /host/usr/local/bin/ctr -n k8s.io ... images list 2>&1)
IMAGE_ID=$(echo "$IMAGES_LIST" | grep -v 'registry.k8s.io' | ... | awk '{print $1}' | head -1)
# awk/head는 호스트(dev server)에서 실행 → 정상 동작
```

**수정 완료**: `scripts/kind-image-load.sh` (2026-03-04).

---

### Phase 3 완료 요약 (2026-03-04)

`test/e2e/sli_e2e_test.go` Phase 3 실 클러스터 E2E 검증 PASS.

- **curlpod 이미지**: `curlimages/curl:kind-cached` (non-latest 태그, `imagePullPolicy: IfNotPresent`)
  - kind 노드 containerd에 사전 로드 (privileged pod 경유)
- **snapshotFetcher 패턴**: before/after 스냅샷 직접 수집 후 harness 주입 (Gap G workaround)
- **실측 결과**:
  ```
  reconcile_total_delta      status=pass   value=1   (VERIFIED >= 1)
  workqueue_adds_total_delta status=pass   value=1
  workqueue_depth_end        status=pass   value=0
  rest_client_requests_total status=pass   value=5
  ```
- **총 소요시간**: 16.06s (curlpod 2회 실행 포함)
- **JSON 아티팩트**: `/tmp/sli-results/` 저장 확인

### 갭 우선순위 전체 현황 (2026-03-04 기준)

| 갭 | 위치 | 상태 | 난이도 | 설명 |
|----|------|------|--------|------|
| 7.1: CurlImage | kube-slint | **해소** | - | SessionConfig.CurlImage 추가(58c0d88) |
| 7.2: TLS skip | kube-slint | **해소** | - | SessionConfig.TLSInsecureSkipVerify 추가(58c0d88) |
| A: Judge 주석 | kube-slint presets.go | 미해소 | 한 줄 | 에러 delta 마킹 비활성 |
| E: GateOnLevel | hello-operator config | 미해소 | 한 줄 | 게이팅 전파 없음 |
| B: 레이블 매칭 | kube-slint engine | 미해소 | 중간 | A/E 효과 무력화 |
| C: ComputeEnd | kube-slint engine | 미해소 | 중간 | gauge 정확도 |
| D: cross-run | kube-slint 신규 pkg | 미해소 | 높음 | 추세 기반 회귀 탐지 |
| **F: imagePullPolicy** | kube-slint client.go | **신규** | 낮음 | air-gapped kind 환경 차단 |
| **G: Start() 미스냅샷** | kube-slint session.go | **신규** | 높음 | curlpod delta=0 설계 불일치 |
