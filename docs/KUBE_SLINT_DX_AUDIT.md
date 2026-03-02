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
