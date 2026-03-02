# TROUBLESHOOTING: Step 1 - Kind 클러스터 생성 실패 분석 및 해결

## 대상 독자

이 문서는 Kubernetes 오퍼레이터 개발에 입문하는 개발자를 위해 작성되었다.
Linux 시스템 관리 경험이 없어도 읽을 수 있도록 비유를 활용하여 설명한다.

---

## 1. 현상: 왜 Kind 클러스터가 만들어지지 않았는가?

다음 명령을 실행하면 아래와 같은 오류가 발생했다.

```
$ kind create cluster --name tilt-study
ERROR: failed to create cluster: running kind with rootless provider requires
setting systemd property "Delegate=yes",
see https://kind.sigs.k8s.io/docs/user/rootless/
```

**메시지 해석:** "rootless(비특권 사용자) 모드로 Kind를 실행하려면, systemd의
Delegate 속성이 yes로 설정되어 있어야 한다."

---

## 2. 개념 설명: cgroup이란 무엇인가?

### 비유: 건물의 전기 배전반

아파트 건물을 상상해보자.

- **건물 전체 전기(루트 cgroup)**: 건물에 공급되는 총 전력량.
- **층별 배전반(user.slice)**: 각 층에 얼마나 전기를 줄지 분배하는 중간 배전반.
- **세대별 차단기(user-1001.slice)**: 101호, 102호 등 각 세대의 전기 차단기.
- **플러그(컨테이너)**: 실제 전자제품(컨테이너 프로세스)이 꽂히는 곳.

**cgroup(Control Group)**은 Linux 커널이 CPU, 메모리, PID(프로세스 수) 등의
시스템 자원을 각 프로세스 그룹에 분배하는 메커니즘이다.

cgroup v2에서는 자원 제어 권한을 부모에서 자식으로 위임(Delegate)해야만
자식 cgroup이 자원을 관리할 수 있다. 이 위임이 없으면, 마치 층별 배전반이
세대에 전기를 보내는 스위치를 열어주지 않은 것과 같다.

```
/sys/fs/cgroup/
  └── user.slice/                    (층별 배전반)
        cgroup.subtree_control = ""  <-- 스위치가 닫혀있음 (문제!)
        └── user-1001.slice/         (세대별 차단기)
              └── session-99.scope/  (현재 세션)
                    └── kind 프로세스  (컨테이너)
```

Kind는 클러스터 노드를 컨테이너로 실행한다. 이 컨테이너가 자체적인 cgroup을
만들려면, 부모 cgroup(user.slice)이 자원 제어 권한을 자식에게 위임(delegate)
해야 한다.

---

## 3. 원인 분석: Rootless 환경의 태생적 제약

### 3.1 Rootless 컨테이너란?

"Rootless" 컨테이너는 root(관리자) 권한 없이 일반 사용자가 컨테이너를 실행하는
기술이다. 보안상 유리하지만, cgroup 자원 제어에 제약이 있다.

### 3.2 발견된 근본 원인

```
진단 명령:
$ cat /sys/fs/cgroup/user.slice/cgroup.subtree_control
(출력 없음 - 빈 상태)
```

`user.slice/cgroup.subtree_control`이 비어있었다. 즉, user.slice가 자식 cgroup에
자원 컨트롤러(cpu, memory, pids)를 전달하지 않아서 컨테이너용 sub-cgroup을
만들 수 없었다.

### 3.3 왜 `Delegate=yes`를 설정해도 해결되지 않았나?

```
# systemd 설정 확인 (이미 yes로 설정됨)
$ systemctl show user@1001.service -p Delegate
Delegate=yes

# 하지만 실제 cgroup 파일은 비어있음
$ cat /sys/fs/cgroup/user.slice/cgroup.subtree_control
(빈 상태)
```

`Delegate=yes` 설정은 user@1001.service 수준에만 적용되었다.
user.slice(부모 배전반) 자체가 자식에게 전기를 보내는 스위치를 열어주지
않았기 때문에, 아래 단계에서 아무리 `Delegate=yes`를 설정해도 실제 cgroup
파일에는 반영되지 않았다.

### 3.4 session-99.scope 수정 시도 실패

```
# 현재 세션 스코프에 직접 쓰기 시도
$ echo "+cpu +memory +pids" > /sys/fs/cgroup/user.slice/user-1001.slice/session-99.scope/cgroup.subtree_control
sh: echo: write error: Device or resource busy
```

현재 세션(session-99.scope)에는 이미 여러 프로세스가 실행 중이다. cgroup v2는
"내부 프로세스가 있는 cgroup의 subtree_control은 변경할 수 없다"는 규칙이 있다.
이것은 건물이 사람이 살고 있는 도중에 세대별 배전반 배선을 바꿀 수 없는 것과 같다.

---

## 4. 해결 방법

### 4.1 즉각 적용: 관리자 권한으로 cgroup 위임 활성화

관리자 권한(Administrative privileges)을 사용하여 user.slice 수준에서
컨트롤러 위임을 강제 활성화했다.

```bash
# user.slice에 cpu, memory, pids 컨트롤러 위임 활성화
echo "+cpu +memory +pids" > /sys/fs/cgroup/user.slice/cgroup.subtree_control

# user-1001.slice에도 동일 적용
echo "+cpu +memory +pids" > /sys/fs/cgroup/user.slice/user-1001.slice/cgroup.subtree_control
```

적용 후 확인:
```
$ cat /sys/fs/cgroup/user.slice/cgroup.subtree_control
cpu memory pids

$ cat /sys/fs/cgroup/user.slice/user-1001.slice/cgroup.subtree_control
cpu memory pids
```

### 4.2 영구 적용: systemd 설정 및 tmpfiles.d 등록

재부팅 후에도 설정이 유지되도록 두 가지 방법으로 영구화했다.

**방법 1: tmpfiles.d (부팅 시 cgroup 파일 쓰기)**
```
# 파일 위치: /etc/tmpfiles.d/rootless-cgroup-delegate.conf
w /sys/fs/cgroup/user.slice/cgroup.subtree_control - - - - +cpu +memory +pids
w /sys/fs/cgroup/user.slice/user-1001.slice/cgroup.subtree_control - - - - +cpu +memory +pids
```

**방법 2: systemd 단위 drop-in (Delegate=yes 설정)**
```
# /etc/systemd/system/user.slice.d/delegate.conf
[Slice]
Delegate=yes

# /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=yes
```

### 4.3 근본적 해결: Rootful Podman으로 Kind 실행

위 설정 후에도 Kind의 내부 검사 로직(validateProvider)이 현재 세션 스코프
(session-99.scope)의 Delegate 속성을 확인하는 방식으로 동작하여 rootless 경로는
여전히 차단 상태였다. (현재 세션 스코프에 프로세스가 있어 subtree_control 변경 불가)

**최종 해결 방법: Rootful Podman 사용**

관리자 권한(Administrative privileges)으로 루트 podman 소켓을 사용하여
Kind 클러스터를 생성했다.

```bash
# 관리자 권한 적용: 루트 podman 소켓(/run/podman/podman.sock) 사용
sudo env \
  KIND_EXPERIMENTAL_PROVIDER=podman \
  DOCKER_HOST=unix:///run/podman/podman.sock \
  ./bin/kind create cluster --name tilt-study
```

실행 결과:
```
Creating cluster "tilt-study" ...
 - Ensuring node image (kindest/node:v1.31.0) ...
 - Preparing nodes ...
 - Writing configuration ...
 - Starting control-plane ...
 - Installing CNI ...
 - Installing StorageClass ...
Set kubectl context to "kind-tilt-study"
```

이 방법은 루트 podman 데몬(전체 시스템 권한으로 실행 중인 podman)을 사용하므로
cgroup 위임 문제를 완전히 우회한다.

재현 가능한 스크립트: `scripts/kind-cluster-init.sh`

---

## 5. 검증: 정상 동작 확인 및 로그 해석

### 5.1 클러스터 상태 확인

```bash
$ kubectl get nodes --context kind-tilt-study
NAME                       STATUS   ROLES           AGE   VERSION
tilt-study-control-plane   Ready    control-plane   Xm    v1.31.0
```

`Ready` 상태가 표시되면 클러스터가 정상 동작 중이다.

### 5.2 오퍼레이터 배포 확인 (`tilt ci`)

```bash
$ tilt ci
# 핵심 출력 (정상):
SUCCESS. All workloads are healthy.
```

### 5.3 컨트롤러 Startup 로그 해석

```
2026-03-02T07:01:21Z  INFO  setup  starting manager
```
의미: 오퍼레이터 매니저가 시작되었다. controller-runtime 프레임워크가 초기화 완료.

```
I0302 07:01:21  leaderelection.go:271  successfully acquired lease
```
의미: 이 파드가 리더 선거에서 승리하여 활성 컨트롤러가 되었다.
(여러 복제본 운영 시 오직 하나의 파드만 리소스를 조정한다.)

```
2026-03-02T07:01:21Z  INFO  Starting workers  {"worker count": 1}
```
의미: 1개의 워커 고루틴이 시작되어 이벤트를 처리할 준비가 되었다.

### 5.4 Reconcile 로그 해석

```
2026-03-02T07:01:43Z  INFO  reconcile hit
  {"controller": "hello", "Hello": {"name":"hello-sample","namespace":"default"},
   "reconcileID": "7523ad67-..."}
```

**reconcile hit**: 컨트롤러가 Hello CR(Custom Resource)에 대한 조정(reconcile) 요청을
처리했다는 의미다.

- `controller`: 이 이벤트를 처리한 컨트롤러 이름 (`hello`)
- `Hello.name`: 대상 CR의 이름 (`hello-sample`)
- `Hello.namespace`: CR이 위치한 네임스페이스 (`default`)
- `reconcileID`: 이 조정 사이클의 고유 ID (디버깅에 활용)

`kubectl apply -f config/samples/demo_v1alpha1_hello.yaml`을 실행하면 이 로그가
즉시 출력되어야 한다. 출력되지 않으면 컨트롤러가 CR 변경 이벤트를 수신하지 못한 것이다.

---

## 6. 환경별 Kind 클러스터 생성 방법 요약

| 환경 | 명령 | 비고 |
|------|------|------|
| Rootless podman + 완전한 cgroup 위임 | `kind create cluster --name tilt-study` | 이상적 환경 |
| Rootless podman + 부분 위임 | `systemd-run --user --scope --property=Delegate=yes kind create ...` | 세션 스코프 우회 |
| Rootful podman (관리자 필요) | `sudo env ... kind create cluster --name tilt-study` | 본 환경 적용 방식 |
| Docker 환경 | `kind create cluster --name tilt-study` (Docker provider 기본값) | Docker가 있으면 자동 감지 |

---

## 7. 핵심 교훈

1. **`Delegate=yes` 설정만으로는 부족하다**: systemd 단위 설정과 실제 cgroup
   파일(subtree_control)이 별도로 관리될 수 있다. 설정 후 반드시 파일을 직접 확인하라.

2. **cgroup 위임은 계층적이다**: 루트부터 현재 세션까지 각 단계의 subtree_control이
   모두 올바르게 설정되어야 한다.

3. **Rootless = 제약 있는 자유**: Rootless 컨테이너는 보안상 유리하지만,
   시스템 수준 자원 제어에는 관리자 개입이 필요한 경우가 있다.

4. **재현성 확보가 중요하다**: `scripts/kind-cluster-init.sh`처럼 클러스터 생성을
   스크립트화하면 팀원과 CI/CD 환경에서 동일하게 재현할 수 있다.
