# kube-slint 소비자 UX 테스트 보고서

**작성일:** 2026-03-07
**검증 저장소:** hello-operator (소비자 측 검증 repo)
**검증 kube-slint 버전:** v1.0.0-rc.1 (go.mod 기준: 58c0d88, 2026-03-02)
**검증 slint-gate 버전:** 678b50c (2026-03-07, hack/slint_gate.py)
**환경:** ko + Tilt + kind (kind-tilt-study, k8s v1.31.0, RHEL 8)

---

## 1. 검증 목적

이 보고서는 kube-slint의 최신 guardrail 흐름을 hello-operator에 붙여보면서
소비자 관점에서 겪은 경험을 솔직하게 기록한다. 목표는 아키텍처적 완성도가 아니라
마찰의 정직한 측정이다.

hello-operator는 임시 소비자 측 검증 프로젝트다. 발견된 모든 마찰 지점,
경로 불일치, 혼란스러운 UX는 조용히 수정하는 대신 의도적으로 보존하고 기록한다.

---

## 2. 현재 kube-slint 연동 상태

### Go 모듈 import

```
github.com/HeaInSeo/kube-slint v1.0.0-rc.1.0.20260302080738-58c0d8811314
```

go.mod는 58c0d88 커밋에 고정되어 있다. 최신 kube-slint는 678b50c (2026-03-07)이며,
Gap G 수정(SnapshotFetcher)과 새로운 slint-gate 도구가 포함되어 있다.
아직 버전을 업데이트하지 않았으며, 아래의 모든 통합 작업은 구버전 기준으로 진행했다.

### 테스트 코드 연동 지점

| 파일 | 연동 내용 |
|---|---|
| test/e2e/sli_integration_test.go | Mock 테스트: httptest.Server + 커스텀 MetricsFetcher를 harness.SessionConfig에 주입 |
| test/e2e/sli_e2e_test.go | E2E 테스트: curlpod 직접 실행 + 수동 snapshotFetcher 워크어라운드 (Gap G) |

### Kubernetes 리소스

| 파일 | 용도 |
|---|---|
| config/rbac/sli_checker_serviceaccount.yaml | SA: sli-checker (kustomize namePrefix 적용 후 → hello-operator-sli-checker) |
| config/rbac/sli_checker_clusterrolebinding.yaml | CRB: sli-checker → metrics-reader ClusterRole |

### Tiltfile 연동

```
local_resource('sli-mock-test', auto_init=False)   # Phase 1: 클러스터 불필요
local_resource('sli-e2e-test', auto_init=False)    # Phase 2/3: 실 클러스터 필요
```

### 이번 사이클에서 새로 추가된 파일

```
.slint/policy.yaml              # 최소 viable policy
hack/run-slint-gate.sh          # 브리지: 최신 summary 탐색 → slint_gate.py 실행
artifacts/.gitkeep              # 생성 아티팩트용 placeholder
```

---

## 3. 실제 measurement summary 경로

### summary가 실제로 작성되는 위치

```
/tmp/sli-results/sli-summary.{runId}.{testCase}.json
```

구체적인 예시:
```
/tmp/sli-results/sli-summary.local-1772888598.hello-sample-create.json
```

특성:
- **위치:** /tmp (프로젝트 디렉토리 외부)
- **파일명:** 동적. runId(UNIX 타임스탬프)와 testCase 문자열 포함
- **고정 경로 없음:** harness는 "latest"라는 안정적인 파일명을 절대 만들지 않음
- **비영속적:** /tmp는 재부팅 시 초기화됨. 커밋 불가

### slint_gate.py가 기본으로 기대하는 경로

```
artifacts/sli-summary.json
```

특성:
- **위치:** 프로젝트 디렉토리 내부
- **파일명:** 고정
- **커밋 또는 CI 아티팩트로 제공되어야 함**

### 갭: 경로 불일치

이번 사이클에서 발견된 가장 중요한 마찰이다.

harness와 gate evaluator가 서로 호환되지 않는 경로 규칙을 사용한다.
이를 연결하는 내장 메커니즘이 없다.

필요한 워크어라운드: `hack/run-slint-gate.sh`가 glob 패턴으로 최신
sli-summary 파일을 찾아 `artifacts/sli-summary.json`으로 복사한 뒤
slint_gate.py를 호출한다.

브리지 스크립트는 testCase 문자열 `hello-sample-create`을 하드코딩한다.
다른 testCase를 사용하는 소비자는 이 문자열을 수동으로 변경해야 한다.
이것은 이식성 위험 요소다.

원인 귀속: **kube-slint** — harness의 ArtifactsDir + 파일명 규칙이
소비자가 주소 지정 가능한 안정적인 경로를 만들지 못함.

---

## 4. `.slint/policy.yaml` 배치

### 배치 결과

`.slint/policy.yaml`을 hello-operator 저장소 루트에 배치했다.

배치 위치는 자연스럽게 느껴진다. kube-slint 자체의 `.slint/` 규칙을 그대로
따르고 있으며, 디렉토리 이름이 오퍼레이터 코드와 guardrail 설정 사이의
경계를 명확히 암시한다.

### 사용한 최소 viable policy

```yaml
schema_version: "slint.policy.v1"
thresholds:
  - name: "workqueue_depth_end_max"
    metric: "workqueue_depth_end"
    operator: "<="
    value: 5
    severity: "fail"
  - name: "reconcile_total_delta_min"
    metric: "reconcile_total_delta"
    operator: ">="
    value: 1
    severity: "fail"
regression:
  enabled: false
first_run:
  default_result: "warn"
  evaluate_thresholds: true
  evaluate_regression: false
baseline:
  required: false
  on_unavailable: "warn"
  on_corrupt: "no_grade"
fail_on:
  - "threshold_miss"
```

### 관찰 사항

어떤 metric ID가 존재하는지 이미 알고 있다면 최소 viable policy 작성은
간단하다. 스키마가 깔끔하고 필드명이 모호하지 않다.

그러나 어떤 metric ID를 참조해도 안전한지 알려면 먼저 sli-summary.json 출력을
읽어야 한다. kube-slint README에는 SLI 프리셋별로 사용 가능한 metric ID 목록이
문서화되어 있지 않다. 소비자는 테스트를 한 번 실행하고 출력을 검사한 후에야
의미 있는 policy를 작성할 수 있다.

---

## 5. slint-gate 연동

### 연동 방식

slint_gate.py는 kube-slint 저장소의 `hack/slint_gate.py`에 위치한다.
pip 패키지나 독립 실행형 바이너리로 배포되지 않는다.

브리지 스크립트 `hack/run-slint-gate.sh`는 hello-operator에 대한 상대 경로로
kube-slint 저장소 위치를 추론한다:

```bash
KUBE_SLINT_DIR="$(cd "${REPO_ROOT}/../kube-slint" && pwd)"
SLINT_GATE_PY="${KUBE_SLINT_DIR}/hack/slint_gate.py"
```

이 방식은 kube-slint가 디스크에서 hello-operator 옆에 checkout되어 있다고
가정한다. 현재 개발 머신에서는 동작하지만, kube-slint도 함께 clone하지 않는 한
CI에서는 깨진다.

의존성: python3 + pyyaml (pip install pyyaml). 현재 호스트에는 모두 준비되어 있음.

### 마찰: slint_gate.py는 독립적으로 배포할 수 없음

실제 소비자는 `pip install kube-slint-gate`를 할 수 없다. 다음을 해야 한다:
1. kube-slint를 별도로 clone 또는 다운로드
2. hack/slint_gate.py 경로를 파악
3. pyyaml을 수동으로 설치

이것은 CI 사용에 있어 의미 있는 도입 장벽이다.

원인 귀속: **kube-slint** — gate evaluator의 독립 배포 없음.

---

## 6. 시나리오별 실행 결과

모든 시나리오는 TestHelloSLIMock(mock 테스트, 실제 클러스터 불필요)이
생성한 sli-summary를 대상으로 실행했다.

### 시나리오 1: first-run, baseline 없음

**명령어:** `bash hack/run-slint-gate.sh`
**Policy:** `.slint/policy.yaml` (regression 비활성화)

```
gate_result       : PASS
evaluation_status : evaluated
measurement_status: ok
baseline_status   : absent_first_run
reasons           : []
checks:
  [pass] workqueue_depth_end_max | observed=0.0 | expected=<= 5
  [pass] reconcile_total_delta_min | observed=3.0 | expected=>= 1
  [pass] reliability-minimum | observed=Complete | expected=>= partial
overall_message   : Policy checks passed.
```

**평가:** 명확하고 올바르다. baseline_status=absent_first_run이 포함된 PASS는
모호하지 않다. 개발자가 문서를 읽지 않아도 이 출력을 이해할 수 있다.
**등급: Easy**

---

### 시나리오 2: measurement summary 파일 없음

**명령어:** 존재하지 않는 summary 경로로 slint_gate.py 실행

```
gate_result       : NO_GRADE
evaluation_status : not_evaluated
measurement_status: missing
reasons           : ['MEASUREMENT_INPUT_MISSING']
overall_message   : Policy or measurement input unavailable; gate not evaluated.
```

**평가:** 올바른 동작이다. NO_GRADE가 적절하다. reason 코드는 명확하다. 그러나
메시지가 소비자에게 어떤 경로가 기대되었는지, 파일이 어디서 와야 하는지를
알려주지 않는다. CI에서 이 결과를 처음 보는 소비자는 먼저 SLI 테스트를 실행하고
출력을 기대 경로로 복사해야 한다는 사실을 즉시 알아채지 못한다.
**등급: Manageable**

---

### 시나리오 3: policy 파일 없음

**명령어:** 존재하지 않는 policy 경로로 slint_gate.py 실행

```
gate_result       : NO_GRADE
evaluation_status : not_evaluated
policy_status     : missing
reasons           : ['POLICY_MISSING']
overall_message   : Policy or measurement input unavailable; gate not evaluated.
```

**평가:** 올바르다. 메시지가 시나리오 2와 동일해서 약간 혼란스럽다(두 가지 다른
실패 모드에 같은 메시지). 소비자는 `policy_status`와 `measurement_status`를
확인해야 둘을 구분할 수 있다.
**등급: Manageable**

---

### 시나리오 4: threshold miss

**Policy:** reconcile_total_delta <= 0 (실제 값은 3)

```
gate_result       : FAIL
evaluation_status : evaluated
reasons           : ['THRESHOLD_MISS']
checks:
  [fail] reconcile_total_delta_max | observed=3.0 | expected=<= 0
overall_message   : Policy violation detected (threshold/regression).
```

**평가:** 명확하고 올바르다. check 항목이 관찰값과 기대값을 정확히 보여준다.
CI 단계에서 job을 적절히 실패시킬 것이다. 관찰값이 표시되어 있어
false positive threshold를 디버깅할 때 유용하다.
**등급: Easy**

---

### 시나리오 5: regression 활성화, baseline 없음 (first-run)

**Policy:** regression.enabled=true, tolerance_percent=5

```
gate_result       : WARN
evaluation_status : partially_evaluated
baseline_status   : absent_first_run
reasons           : ['BASELINE_ABSENT_FIRST_RUN']
checks:
  [pass] workqueue_depth_end_max | observed=0.0 | expected=<= 5
overall_message   : Policy evaluated with non-blocking warnings.
```

**평가:** 올바른 first-run 동작이다. WARN은 비차단적이다. 소비자는 자신이
first-run 모드에 있고 baseline이 생기면 regression이 평가될 것임을 이해한다.
그러나 baseline을 어떻게 생성하거나 저장하는지에 대한 안내가 없다.
이번 실행 출력을 baseline으로 저장하려면 어디에 저장해야 하는지,
다음 번에 어떤 명령을 실행해야 하는지 소비자는 의문이 남는다.
**등급: Manageable (단, baseline lifecycle이 소비자에게 문서화되어 있지 않음)**

---

### 시나리오 6: skip 상태인 metric을 policy threshold로 참조

**Policy:** reconcile_success_delta >= 1 (이 metric은 레이블 불일치로 sli-summary에서 "skip")

```
gate_result       : NO_GRADE
evaluation_status : partially_evaluated
reasons           : ['MEASUREMENT_INPUT_MISSING']
checks:
  [no_grade] reconcile_success_delta_min | observed=None | message=metric missing or invalid threshold target
overall_message   : Policy could not be fully evaluated.
```

**평가:** 모든 시나리오 중 가장 혼란스러운 결과다.

소비자는 `reconcile_success_delta`를 policy에 작성한다 — 오퍼레이터 품질 게이트에
완전히 합리적인 선택이다. metric 이름은 유효하고 DefaultV3Specs 문서에 등장한다.
그러나 실제로 이 metric은 레이블 불일치(Gap A)로 항상 "skip" 상태다:
- controller-runtime이 노출하는 형태: `controller_runtime_reconcile_total{controller="hello",result="success"}`
- DefaultV3Specs가 필터링하는 형태: `controller_runtime_reconcile_total{result="success"}`

gate는 reason MEASUREMENT_INPUT_MISSING과 함께 NO_GRADE를 반환한다. metric이
수집 중에 의도적으로 skip되었다거나 이것이 default SLI 프리셋의 알려진 한계라는
표시가 전혀 없다.

이유를 이해하려면 소비자는 다음을 해야 한다:
1. NO_GRADE 결과를 인지
2. artifacts/sli-summary.json을 열기
3. reconcile_success_delta를 status="skip", reason="missing input metrics"로 찾기
4. inputsMissing을 보고 레이블 불일치를 파악
5. DX audit 문서를 읽어 Gap A 설명 찾기

이것은 설정 오류처럼 보이지만 실제로는 라이브러리 제한인 문제에 대한
5단계 디버깅 체인이다.

**등급: Painful**

---

## 7. 마찰 및 버그 목록

### F-1: sli-summary 경로 불일치 (Painful)

**증상:** harness는 `/tmp/sli-results/sli-summary.{runId}.{testCase}.json`에
기록하지만 slint_gate.py 기본값은 `artifacts/sli-summary.json`이다.

**워크어라운드:** `hack/run-slint-gate.sh`가 최신 파일을 복사한다.

**워크어라운드의 문제점:** testCase 문자열(`hello-sample-create`)이 스크립트에
하드코딩되어 있다. 다른 testCase를 사용하는 오퍼레이터는 수동으로 변경해야 한다.

**귀속:** kube-slint — harness는 per-run 파일과 함께 안정적인 고정명
"latest" 아티팩트를 지원해야 한다.

---

### F-2: slint_gate.py 독립 배포 불가 (Manageable)

**증상:** 소비자는 gate evaluator를 `pip install`할 수 없다. kube-slint를
clone하고 경로를 파악하고 pyyaml을 수동으로 설치해야 한다.

**워크어라운드:** 로컬 kube-slint clone에서 상대 경로로 참조.

**워크어라운드의 문제점:** kube-slint도 함께 clone하지 않으면 CI에서 깨진다.

**귀속:** kube-slint — evaluator 패키징 없음.

---

### F-3: skip metric이 policy에서 조용히 NO_GRADE가 됨 (Painful)

**증상:** reconcile_success_delta와 reconcile_error_delta가 레이블 불일치(Gap A)로
sli-summary에서 "skip" 상태다. policy에서 참조하면 reason MEASUREMENT_INPUT_MISSING과
함께 NO_GRADE를 생성한다 — measurement summary의 skip 상태와 연결하는 설명 없음.

**워크어라운드:** policy에서 skip metric을 참조하지 않는다. reconcile_total_delta를
대신 사용한다.

**문제점:** 소비자는 sli-summary와 DX audit를 읽지 않으면 이를 알 수 없다.
metric 이름이 유효해 보인다.

**귀속:** kube-slint — slint_gate.py는 metric ID가 sli-summary에 status="skip"으로
존재하는 경우를 감지하여 `MEASUREMENT_INPUT_MISSING` 대신
`METRIC_WAS_SKIPPED_IN_COLLECTION`과 같은 더 구체적인 reason 코드를 발행해야 한다.

---

### F-4: baseline lifecycle 문서화 없음 (Manageable)

**증상:** 첫 번째 실행 후 소비자는 BASELINE_ABSENT_FIRST_RUN과 함께 WARN을
보지만, 현재 실행을 다음 실행의 baseline으로 승격하는 방법에 대한 안내가 없다.

**워크어라운드:** artifacts/sli-summary.json을 "baseline.json" 경로로 수동 복사하고
--baseline 옵션으로 slint_gate.py에 전달.

**귀속:** kube-slint — 소비자를 위한 baseline 업데이트 워크플로우 문서화 없음.

---

### F-5: kind 환경에서 curlpod 이미지 사전 로드 필요 (Manageable)

**증상:** `curlimages/curl:latest`는 `imagePullPolicy: Always`를 트리거하여
kind 노드에서 ImagePullBackOff를 발생시킨다(인터넷 미연결).
`curlimages/curl:kind-cached` 사전 로드가 필요하다.

**워크어라운드:** KUBE_SLINT_DX_AUDIT.md Gap F에 문서화됨. kind-image-load.sh를
통해 이미지 사전 로드.

**귀속:** kube-slint — CurlImage 기본값이 non-latest 고정 태그여야 하며,
kind 사전 로드 요구사항이 README에 있어야 한다.

---

### F-6: E2E 테스트에서 snapshotFetcher 워크어라운드 여전히 필요 (Manageable)

**증상:** go.mod가 58c0d88에 고정되어 있다. SnapshotFetcher(Gap G 수정)는
4d3867c에서 추가됐다. 업데이트 없이는 E2E 테스트가 curlpod를 두 번 호출하여
snapshotFetcher를 수동으로 구현해야 한다(CR 적용 전/후).

**상태:** kube-slint는 4d3867c에서 수정했다. hello-operator는 아직 go.mod를
업데이트하지 않았다. 워크어라운드는 도입 증거로 sli_e2e_test.go에 그대로 남아 있다.

**귀속:** hello-operator (go.mod 업데이트 대기 중).

---

### F-7: RBAC serviceaccount 이름이 kustomize namePrefix에 의존 (Manageable)

**증상:** sli_checker_serviceaccount.yaml은 `name: sli-checker`로 선언한다.
kustomize `namePrefix: hello-operator-` 적용 후 `hello-operator-sli-checker`가 된다.
테스트 코드는 prefix 적용 후 이름을 하드코딩한다. namePrefix를 모르는 소비자는
인증 실패와 오해를 유발하는 권한 오류를 보게 된다.

**귀속:** hello-operator (문서화 갭) / kube-slint (kustomize와의 RBAC 명명 규칙
안내 없음).

---

## 8. 쉬웠던 것

1. **`slint_gate.py` 출력을 읽기 쉽다.** 모든 필드가 명확하게 명명되어 있다.
   개발자가 문서를 읽지 않아도 gate 결과를 이해할 수 있다.

2. **threshold 평가가 모호하지 않다.** 관찰값 대비 기대값이 포함된 PASS/FAIL은
   policy 위반을 디버깅할 때 개발자가 필요로 하는 바로 그것이다.

3. **policy 파일 형식이 깔끔하다.** YAML 스키마가 작고 읽기 쉽다.
   metric ID를 알고 나면 최소 viable policy 작성에 5분도 걸리지 않는다.

4. **first-run / baseline 없음 동작이 올바르고 비차단적이다.** baseline_status=absent_first_run이
   포함된 PASS는 혼란이나 경보를 주지 않는다.

5. **policy 없음 / summary 없음 → NO_GRADE (충돌이나 FAIL 아님).** gate가
   gracefully 저하된다. 누락된 입력이 false positive 실패를 만들지 않는다.

---

## 9. 고통스러웠던 것

1. **올바른 sli-summary 경로 찾기.** harness는 /tmp에 동적 파일명으로 기록한다.
   gate evaluator는 프로젝트 내부의 고정 경로를 기대한다. 내장 브리지가 없다.
   소비자가 자체 브리지 스크립트를 작성해야 한다.

2. **reconcile_success_delta를 사용할 수 없는 이유 이해하기.** 레이블 불일치(Gap A)로
   가장 자연스러운 품질 신호(성공률)가 조용히 사용 불가능해진다. policy가
   구체적인 설명 없이 일반적인 reason과 함께 NO_GRADE를 반환한다.

3. **baseline lifecycle에 대한 안내 없음.** first-run 후 소비자는 WARN을 보지만
   baseline을 수립하기 위해 다음에 무엇을 해야 할지 알 수 없다.

---

## 10. 일반화 가능성 평가

### 다른 Kubebuilder 오퍼레이터에 일반화될 수 있는 것

- `.slint/policy.yaml` 배치 위치 및 형식
- slint_gate.py 호출 패턴 (경로 해결 후)
- E2E 테스트에서의 SessionConfig / NewSession / Start / End API 패턴
- RBAC 리소스 구조 (SA + CRB)

### 변경 없이는 일반화되지 않는 것

- `hack/run-slint-gate.sh`가 `hello-sample-create`를 testCase 이름으로 하드코딩
- `hack/run-slint-gate.sh`가 sibling 디렉토리 가정으로 kube-slint를 해결
- 테스트 코드가 `hello-operator-sli-checker`(namePrefix 적용 후 SA 이름)를 하드코딩
- 두 테스트 파일 모두 ArtifactsDir로 `/tmp/sli-results`를 하드코딩

두 번째 오퍼레이터를 위해 소비자는 최소한 다음을 편집해야 한다:
- SessionConfig의 ArtifactsDir
- run-slint-gate.sh의 testCase 이름
- sli_e2e_test.go의 SA 이름
- Policy metric threshold

3개 파일에서 4번의 수동 편집이 필요하다. 재현 가능하지만 이 문서 없이는
발견할 수 없다.

---

## 11. kube-slint 개선 제안

| ID | 문제 | 제안 |
|---|---|---|
| SG-1 | 경로 불일치 | harness가 per-run 파일과 함께 `sli-summary.latest.json` symlink 또는 고정 별칭을 지원해야 함 |
| SG-2 | slint_gate.py 배포 | 독립 패키지로 배포하거나 이를 가져오는 Makefile 타겟에 내장 |
| SG-3 | skip metric → NO_GRADE | slint_gate.py가 metric이 status="skip"으로 results에 존재하는 경우를 감지하여 `MEASUREMENT_INPUT_MISSING` 대신 `METRIC_WAS_SKIPPED_IN_COLLECTION` 발행 |
| SG-4 | baseline lifecycle | `--save-as-baseline` 플래그 추가 또는 실행을 baseline으로 승격하는 정확한 워크플로우 문서화 |
| SG-5 | 레이블 불일치 (Gap A) | DefaultV3Specs에서 어떤 metric이 정확한 레이블 매칭을 요구하고 어떤 것이 집계 접근을 사용하는지 문서화 |
| SG-6 | CurlImage 태그 (Gap F) | 기본 CurlImage가 고정된 non-latest 태그여야 하며, kind 사전 로드 요구사항을 README에 명시 |

---

## 12. hello-operator 개선 제안

| ID | 문제 | 제안 |
|---|---|---|
| HO-1 | /tmp의 ArtifactsDir | 프로젝트 디렉토리 내 `artifacts/`로 변경; .gitignore에 추가 |
| HO-2 | 브리지 스크립트 testCase 하드코딩 | 기본값이 있는 인수로 받기; 명명 규칙 문서화 |
| HO-3 | 테스트에서 SA 이름 하드코딩 | kustomize namePrefix에서 파생하거나 값을 명확히 문서화 |
| HO-4 | go.mod 고정 버전 | snapshotFetcher 워크어라운드 제거를 위해 4d3867c 이상으로 업데이트 |

---

## 13. 최종 평가

| 평가 항목 | 등급 | 비고 |
|---|---|---|
| 도입 용이성 | Manageable | Go import와 기본 harness API는 깔끔함; 경로 브리지가 고통스러움 |
| 계측 정확성 | Easy | SLI 신호가 올바르게 수집됨; mock 테스트가 안정적 |
| 결과 이해도 | Manageable | PASS/FAIL/WARN은 명확함; skip metric에서 오는 NO_GRADE는 혼란스러움 |
| 마찰 노출도 | Painful | 경로 불일치, skip metric → NO_GRADE, baseline lifecycle 갭 |
| 일반화 가능성 | Manageable | 패턴은 재사용 가능하지만 두 번째 오퍼레이터에 4번의 수동 편집 필요 |

**종합: Manageable — 통합은 작동하지만, 이 문서 없이 혼자 진행했다면 경로 불일치와
skip metric NO_GRADE 상황을 디버깅하는 데 상당한 시간을 소비했을 것이다.**
