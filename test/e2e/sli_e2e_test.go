//go:build e2e

// Package e2e contains integration tests for hello-operator.
//
// SLI E2E Test (curlpod fetcher, 실제 클러스터 필요)
//
// 이 테스트는 kind-tilt-study 클러스터에 배포된 오퍼레이터를 대상으로
// kube-slint curlpod fetcher를 통해 실제 /metrics 엔드포인트에서
// SLI를 측정한다.
//
// 전제조건:
//   - kind-tilt-study 클러스터 실행 중
//   - hello-operator 배포 완료 (tilt up 또는 tilt ci)
//   - hello-operator-sli-checker ServiceAccount 생성 완료 (config/rbac/)
//   - kubectl이 PATH에 존재하고 kind-tilt-study 컨텍스트 사용 중
//
// 실행 방법:
//
//	E2E_SLI=1 go test ./test/e2e/ -run TestHelloSLIE2E -v -tags e2e -timeout 3m
//
// [설계 노트: snapshotFetcher 패턴]
//
// kube-slint engine.Execute()는 session.End() 내부에서 fetcher를 두 번 호출한다:
//
//	start, _ := e.fetcher.Fetch(ctx, cfg.StartedAt)
//	end, _   := e.fetcher.Fetch(ctx, cfg.FinishedAt)
//
// curlpod fetcher는 at time.Time 파라미터를 무시하고 항상 현재 상태를 반환한다.
// 따라서 CR 적용 후 5초 대기하면 두 번의 fetch 모두 post-reconcile 상태를 보게 되어
// delta = 0이 된다.
//
// 해결: 테스트가 직접 curlpod를 두 번 실행하여 before/after 스냅샷을 캡처하고,
// snapshotFetcher를 통해 harness에 주입한다.
// → Start() = pre-fetch start, End() = fetch end, delta = 실제 reconcile 변화량
//
// 이 패턴은 kube-slint Gap G (session.Start() 미스냅샷)의 워크어라운드다.
// kube-slint 개선 제안: docs/KUBE_SLINT_DX_AUDIT.md [Gap G] 참조.
package e2e

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/HeaInSeo/kube-slint/pkg/slo/fetch"
	"github.com/HeaInSeo/kube-slint/pkg/slo/fetch/curlpod"
	"github.com/HeaInSeo/kube-slint/pkg/slo/fetch/promtext"
	"github.com/HeaInSeo/kube-slint/test/e2e/harness"
)

const (
	sliNamespace          = "hello-operator-system"
	sliMetricsSvcName     = "hello-operator-controller-manager-metrics-service"
	sliServiceAccountName = "hello-operator-sli-checker"
	sliSampleCR           = "../../config/samples/demo_v1alpha1_hello.yaml"
	// kind-tilt-study 클러스터는 인터넷 미연결이므로 pre-loaded 이미지를 사용한다.
	// "latest" 태그는 imagePullPolicy: Always(기본값)가 되어 kind 노드에서 ImagePullBackOff를 유발한다.
	// "kind-cached" 태그(non-latest)는 imagePullPolicy: IfNotPresent(기본값)가 적용된다.
	// 이미지 사전 로드: scripts/kind-image-load.sh 또는 아래 1회성 명령어 참조.
	//   podman tag curlimages/curl:latest curlimages/curl:kind-cached
	//   podman save curlimages/curl:kind-cached | kubectl exec -i -n kube-system <helper-pod> -- ...
	sliCurlImage = "curlimages/curl:kind-cached"
)

// snapshotFetcher는 미리 수집된 시작/종료 스냅샷을 harness에 주입한다.
//
// engine.Execute()가 End() 내에서 Fetch()를 두 번 호출할 때:
//   - 첫 번째 호출: pre-CR 적용 스냅샷(시작) 반환
//   - 두 번째 호출: post-reconcile 스냅샷(종료) 반환
//
// 이렇게 하면 실제 reconcile delta가 정확히 계산된다.
type snapshotFetcher struct {
	startValues map[string]float64
	endValues   map[string]float64
	call        int
}

func (f *snapshotFetcher) Fetch(_ context.Context, at time.Time) (fetch.Sample, error) {
	f.call++
	if f.call == 1 {
		return fetch.Sample{At: at, Values: f.startValues}, nil
	}
	return fetch.Sample{At: at, Values: f.endValues}, nil
}

// TestHelloSLIE2E는 실제 클러스터에서 curlpod fetcher로 SLI를 측정한다.
//
// 검증 항목:
//   - curlpod fetcher가 HTTPS /metrics 엔드포인트에서 메트릭을 수집할 수 있음
//   - reconcile_total_delta >= 1 (CR 생성 후 최소 1회 Reconcile 확인)
//   - 에러 delta = 0 (정상 경로)
func TestHelloSLIE2E(t *testing.T) {
	if os.Getenv("E2E_SLI") != "1" {
		t.Skip("E2E_SLI=1 환경변수가 설정되지 않아 스킵합니다. 실행하려면: E2E_SLI=1 go test -tags e2e -run TestHelloSLIE2E")
	}
	t.Setenv("SLINT_DISABLE_DISCOVERY", "1")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	// 1. sli-checker SA용 Bearer 토큰 발급
	token, err := kubectlCreateToken(sliServiceAccountName, sliNamespace)
	if err != nil {
		t.Fatalf("[sli-e2e] sli-checker SA 토큰 발급 실패: %v\n"+
			"  힌트: 'kubectl get sa -n %s' 로 SA 존재 여부 확인.\n"+
			"  tilt up 또는 kubectl apply -k config/overlays/kind 으로 배포 필요.", err, sliNamespace)
	}
	t.Logf("[sli-e2e] sli-checker 토큰 발급 완료 (len=%d)", len(token))

	// 2. 오퍼레이터 파드 실행 여부 확인
	if err := waitForOperatorReady(t, sliNamespace, 30*time.Second); err != nil {
		t.Fatalf("[sli-e2e] 오퍼레이터 파드 미준비: %v", err)
	}

	// 3. 기존 hello-sample CR 정리 (재현 가능성 확보)
	_ = kubectlDeleteSample(sliSampleCR)
	time.Sleep(2 * time.Second)

	// 4. 시작 스냅샷 수집 (CR 적용 전)
	//    [설계 노트] engine.Execute()는 End() 내부에서 Fetch()를 두 번 호출한다.
	//    curlpod fetcher는 매번 현재 상태를 반환하므로, CR 적용 후 End()를 호출하면
	//    두 번 모두 post-reconcile 상태를 보게 되어 delta=0이 된다.
	//    따라서 CR 적용 전에 직접 curlpod를 실행하여 시작값을 캡처해야 한다.
	t.Log("[sli-e2e] 시작 스냅샷 수집 중 (CR 적용 전)...")
	startValues, err := fetchMetricsViaCurlpod(ctx, t, sliNamespace, sliMetricsSvcName, sliServiceAccountName, token, sliCurlImage)
	if err != nil {
		t.Fatalf("[sli-e2e] 시작 스냅샷 수집 실패: %v", err)
	}
	t.Logf("[sli-e2e] 시작 스냅샷 수집 완료 (메트릭 수: %d)", len(startValues))
	if v, ok := startValues["controller_runtime_reconcile_total"]; ok {
		t.Logf("[sli-e2e]   reconcile_total (시작): %.0f", v)
	}

	// 5. 샘플 CR 적용 → Reconcile 트리거
	t.Logf("[sli-e2e] hello-sample CR 적용 중: %s", sliSampleCR)
	if out, err := kubectlApplySample(sliSampleCR); err != nil {
		t.Fatalf("[sli-e2e] CR 적용 실패: %v\n  출력: %s", err, out)
	}
	t.Log("[sli-e2e] hello-sample CR 적용 완료")

	defer func() {
		_ = kubectlDeleteSample(sliSampleCR)
		t.Log("[sli-e2e] hello-sample CR 삭제 완료 (cleanup)")
	}()

	// 6. Reconcile 안정화 대기
	t.Log("[sli-e2e] Reconcile 안정화 대기 (5s)...")
	time.Sleep(5 * time.Second)

	// 7. 종료 스냅샷 수집 (reconcile 완료 후)
	t.Log("[sli-e2e] 종료 스냅샷 수집 중 (CR 적용 후)...")
	endValues, err := fetchMetricsViaCurlpod(ctx, t, sliNamespace, sliMetricsSvcName, sliServiceAccountName, token, sliCurlImage)
	if err != nil {
		t.Fatalf("[sli-e2e] 종료 스냅샷 수집 실패: %v", err)
	}
	t.Logf("[sli-e2e] 종료 스냅샷 수집 완료 (메트릭 수: %d)", len(endValues))
	if v, ok := endValues["controller_runtime_reconcile_total"]; ok {
		t.Logf("[sli-e2e]   reconcile_total (종료): %.0f", v)
	}

	// 8. SLI 세션: snapshotFetcher로 pre-captured 값 주입
	//    harness는 리포팅(JSON 아티팩트)과 SLI spec 평가에만 사용한다.
	session := harness.NewSession(harness.SessionConfig{
		Namespace:             sliNamespace,
		MetricsServiceName:    sliMetricsSvcName,
		TestCase:              "hello-sample-create",
		Suite:                 "hello-operator-sli",
		ServiceAccountName:    sliServiceAccountName,
		Token:                 token,
		TLSInsecureSkipVerify: true,
		ArtifactsDir:          "/tmp/sli-results",
		// snapshotFetcher 주입: engine의 두 번의 Fetch() 호출에 각각 start/end 스냅샷 반환
		Fetcher: &snapshotFetcher{startValues: startValues, endValues: endValues},
	})

	session.Start()
	t.Log("[sli-e2e] SLI 세션 종료 스냅샷 처리 중...")
	sum, err := session.End(ctx)
	if err != nil {
		t.Logf("[sli-e2e] session.End() 오류 (non-fatal): %v", err)
	}

	if sum == nil {
		t.Fatal("[sli-e2e] FAIL: summary가 nil임 (session.End()가 nil 반환)")
	}

	// 9. 결과 출력 및 검증
	t.Logf("[sli-e2e] SLI 결과 (%d항목):", len(sum.Results))
	var reconcileTotalDelta *float64
	var reconcileErrorDelta *float64

	for _, r := range sum.Results {
		val := "<nil>"
		if r.Value != nil {
			val = fmt.Sprintf("%.0f", *r.Value)
		}
		t.Logf("  %-42s  status=%-6s  value=%s", r.ID, r.Status, val)

		if r.ID == "reconcile_total_delta" {
			reconcileTotalDelta = r.Value
		}
		if r.ID == "reconcile_error_delta" {
			reconcileErrorDelta = r.Value
		}
	}

	// reconcile_total_delta >= 1 검증
	if reconcileTotalDelta == nil {
		t.Error("[sli-e2e] FAIL: reconcile_total_delta 결과 없음")
	} else if *reconcileTotalDelta < 1 {
		t.Errorf("[sli-e2e] FAIL: reconcile_total_delta=%.0f, 최소 1 이상이어야 함", *reconcileTotalDelta)
	} else {
		t.Logf("[sli-e2e] reconcile_total_delta=%.0f (VERIFIED >= 1)", *reconcileTotalDelta)
	}

	// reconcile_error_delta = 0 검증 (에러 없음)
	if reconcileErrorDelta != nil && *reconcileErrorDelta > 0 {
		t.Errorf("[sli-e2e] FAIL: reconcile_error_delta=%.0f, 0이어야 함", *reconcileErrorDelta)
	} else if reconcileErrorDelta != nil {
		t.Logf("[sli-e2e] reconcile_error_delta=%.0f (VERIFIED = 0)", *reconcileErrorDelta)
	}

	if len(sum.Results) == 0 {
		t.Error("[sli-e2e] FAIL: SLI 결과 항목 없음")
	}

	t.Log("[sli-e2e] PASS - curlpod 기반 실제 클러스터 SLI 측정 완료")
}

// fetchMetricsViaCurlpod는 curlpod를 직접 실행하여 /metrics를 수집하고 파싱한다.
func fetchMetricsViaCurlpod(ctx context.Context, t *testing.T, ns, svcName, saName, token, curlImage string) (map[string]float64, error) {
	t.Helper()
	client := curlpod.New(nil, nil)
	client.TLSInsecureSkipVerify = true

	pod := &curlpod.CurlPod{
		Client:             client,
		Namespace:          ns,
		MetricsServiceName: svcName,
		ServiceAccountName: saName,
		Token:              token,
		Image:              curlImage,
	}

	raw, err := pod.Run(ctx, 5*time.Minute, 2*time.Minute)
	if err != nil {
		return nil, fmt.Errorf("curlpod 실행 실패: %w", err)
	}

	return parseMetricsText(raw)
}

// parseMetricsText는 Prometheus 텍스트 포맷을 파싱하여 unlabeled 집계도 추가한다.
// harness 내부의 parsePrometheusText와 동일한 로직.
func parseMetricsText(raw string) (map[string]float64, error) {
	base, err := promtext.ParseTextToMap(strings.NewReader(raw))
	if err != nil {
		return nil, err
	}
	out := make(map[string]float64, len(base))
	for key, val := range base {
		out[key] = val
		if idx := strings.Index(key, "{"); idx > 0 {
			name := key[:idx]
			out[name] = out[name] + val
		}
	}
	return out, nil
}

// kubectlCreateToken은 지정된 SA의 Bearer 토큰을 발급한다.
func kubectlCreateToken(saName, namespace string) (string, error) {
	cmd := exec.Command("kubectl", "create", "token", saName, "-n", namespace)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("kubectl create token %s -n %s: %w", saName, namespace, err)
	}
	return strings.TrimSpace(string(out)), nil
}

// waitForOperatorReady는 오퍼레이터 파드가 Running/Ready 상태가 될 때까지 기다린다.
func waitForOperatorReady(t *testing.T, namespace string, timeout time.Duration) error {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		cmd := exec.Command("kubectl", "get", "pods", "-n", namespace,
			"-l", "control-plane=controller-manager",
			"--field-selector=status.phase=Running",
			"-o", "name")
		out, err := cmd.Output()
		if err == nil && strings.TrimSpace(string(out)) != "" {
			t.Logf("[sli-e2e] 오퍼레이터 파드 Ready: %s", strings.TrimSpace(string(out)))
			return nil
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("오퍼레이터 파드가 %s 내에 Ready 상태가 되지 않았음", timeout)
}

// kubectlApplySample은 샘플 CR을 클러스터에 적용한다.
func kubectlApplySample(path string) (string, error) {
	cmd := exec.Command("kubectl", "apply", "-f", path)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// kubectlDeleteSample은 샘플 CR을 삭제한다 (best-effort).
func kubectlDeleteSample(path string) error {
	cmd := exec.Command("kubectl", "delete", "-f", path, "--ignore-not-found=true")
	return cmd.Run()
}
