<h1 align="center">code2</h1>

<p align="center"><b>내 AWS 계정에 만드는 브라우저용 개인 VS Code 개발 서버</b><br>
CloudFront → private EC2(Graviton) → code-server, Cognito 로그인(MFA)</p>

---

## 한눈에 보기

- CloudFormation 스택 하나로 **전용 VPC, private EC2, CloudFront, Cognito 로그인**이 모두 만들어집니다. 미리 준비할 네트워크나 리소스는 없습니다.
- 배포가 끝나면 받은 URL에 접속해 Cognito로 로그인(암호 + TOTP)합니다. 로그인하면 바로 VS Code가 열립니다.
- 서버는 공인 IP가 없는 private 서브넷의 EC2(기본 `t4g.large`, 2 vCPU / 8 GiB)입니다. 외부에서 들어오는 길은 **CloudFront(HTTPS)** 와 **EC2 Instance Connect Endpoint(SSH, IAM 인증)** 두 가지뿐입니다.
- 작업 공간(`/home`)은 별도 EBS 볼륨에 있어서 인스턴스를 바꿔도 남습니다.
- 도메인은 없어도 됩니다. 기본으로 CloudFront 주소(`https://dxxxx.cloudfront.net`)를 쓰고, Route 53 도메인이 있으면 `code.example.com` 같은 주소로 붙일 수 있습니다.

## 빠른 시작

필요한 것: AWS 계정, AWS CLI v2, `jq`, 관리자 수준 자격 증명(VPC, EC2, IAM, CloudFront, Cognito, SSM을 만듭니다). SSH와 Session Manager를 쓰려면 [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)도 설치합니다.

```bash
git clone https://github.com/conft2k/code2.git && cd code2

export AWS_REGION=ap-northeast-2              # 원하는 리전
export CODE2_ADMIN_EMAIL=you@example.com      # 임시 암호를 받을 메일
# export CODE2_ADMIN_USER=alice               # 로그인 이름 (기본 admin)
# export CODE2_DOMAIN=code.example.com        # 선택: 내 도메인 (아래 "내 도메인 쓰기")

infra/deploy.sh stack plan     # 변경 세트만 만들고 내용을 보여 줍니다
infra/deploy.sh stack apply    # 실행 (약 10–15분)
infra/deploy.sh status         # URL 확인, 서비스가 active active 이면 준비 완료
```

1. `CODE2_ADMIN_EMAIL`로 임시 암호가 옵니다(7일 유효).
2. `status`에 나온 URL에 접속해 임시 암호로 로그인합니다.
3. 새 암호(12자 이상)를 정하고 인증 앱(Google Authenticator, 1Password 등)에 TOTP를 등록합니다.

> 스택이 끝난 뒤에도 인스턴스는 CloudFront 배포가 완료될 때까지 기다렸다가 oauth2-proxy를 켭니다. 처음 몇 분 동안 502가 보이면 잠시 후 다시 시도합니다.

### 내 도메인 쓰기 (선택)

1. Route 53에 공개 호스티드 존(예: `example.com`)이 있어야 합니다.
2. **us-east-1**에 `*.example.com` 또는 `code.example.com`을 포함하는 발급 완료된 ACM 인증서가 있어야 합니다(CloudFront용).
3. 첫 `stack plan` 전에 `CODE2_DOMAIN=code.example.com`을 지정합니다. 스크립트가 호스티드 존과 인증서를 찾아 넣고, A/AAAA 레코드를 만듭니다. 존 이름이 도메인에서 첫 레이블을 뺀 것과 다르면 `CODE2_ZONE`으로 지정합니다.

도메인은 처음 만들 때 정합니다. 나중에 바꾸면 Cognito 콜백 주소와 인스턴스 설정이 어긋나므로, 스택을 새로 만드는 편이 안전합니다.

## 동작 아키텍처

### 전체 구성

<p align="center">
  <img src="docs/architecture.png" alt="code2 아키텍처: 브라우저 → CloudFront → VPC origin → private subnet의 EC2(oauth2-proxy → code-server, /home EBS). Cognito 로그인, SSM으로 부팅 설정, EC2 Instance Connect Endpoint로 SSH, NAT Gateway로 아웃바운드" width="100%">
</p>

실선은 데이터가 지나는 경로이고, 점선은 인증·설정 같은 제어 경로입니다. 바깥에서 들어오는 길은 CloudFront와 EC2 Instance Connect Endpoint 두 곳뿐이고, 인스턴스에는 공인 IP가 없습니다. dnf 저장소 같은 S3 트래픽은 그림에 없는 S3 게이트웨이 엔드포인트로 NAT를 거치지 않고 나갑니다.

### 브라우저 접속 흐름

1. 브라우저가 code2 URL로 접속합니다. CloudFront가 TLS를 끝내고, 캐시 없이 모든 헤더와 쿠키를 그대로 실어 VPC origin으로 인스턴스의 `:80`에 전달합니다.
2. **oauth2-proxy**가 세션 쿠키(`_code2`)를 확인합니다. 쿠키가 없으면 Cognito 관리형 로그인 페이지로 보냅니다. Authorization code + PKCE(S256) 방식입니다.
3. 사용자가 암호와 TOTP로 로그인하면 Cognito가 `/oauth2/callback`으로 되돌려 보냅니다. oauth2-proxy는 코드를 토큰으로 바꾸고 ID 토큰을 검증한 뒤 세션 쿠키를 발급합니다.
4. 이후 요청은 oauth2-proxy가 `127.0.0.1:8080`의 **code-server**로 프록시합니다. 에디터와 터미널이 쓰는 WebSocket도 같은 경로로 지나갑니다. code-server는 `--auth none`이라 따로 로그인을 묻지 않고, 루프백에만 열려 있어서 oauth2-proxy를 거치지 않고는 닿을 수 없습니다.
5. 세션은 최대 12시간 유지됩니다. oauth2-proxy가 30분마다 refresh 토큰으로 갱신하고, refresh 토큰(12시간)이 만료되면 다시 로그인해야 합니다.

### 부팅 순서

CloudFront 배포는 인스턴스를 가리키므로, 인스턴스가 먼저 만들어지고 CloudFront 주소와 Cognito 클라이언트는 그 뒤에 정해집니다. 그래서 스택이 이 두 값을 SSM 파라미터 `/<스택 이름>/oauth2-proxy`에 써 두고, 인스턴스는 부팅할 때 이 값이 나타날 때까지(최대 30분) 기다렸다가 oauth2-proxy를 설정합니다. code-server는 그 전에 먼저 켜집니다.

### SSH 접속 흐름

1. `aws ec2-instance-connect send-ssh-public-key`로 일회용 공개 키를 인스턴스에 넣습니다. 키는 60초 동안만 유효합니다.
2. `aws ec2-instance-connect open-tunnel`이 IAM 인증을 거쳐 같은 VPC의 EC2 Instance Connect Endpoint까지 터널을 엽니다.
3. 엔드포인트가 인스턴스의 22번 포트에 연결합니다. 엔드포인트 보안 그룹은 인스턴스의 22번으로 나가는 것만 허용합니다.

`infra/deploy.sh ssh`가 이 세 단계를 한 번에 처리합니다.

### 보안

| 영역 | 설정 |
|---|---|
| 인바운드 | 인스턴스 보안 그룹: `:80`은 VPC 대역에서만(CloudFront VPC origin ENI), `:22`는 EICE 보안 그룹에서만 허용합니다. 공인 IP는 없습니다 |
| 로그인 | User Pool은 관리자만 계정을 만들 수 있고, **TOTP MFA가 필수**입니다. 암호는 최소 12자이며 소문자와 숫자를 반드시 넣어야 합니다. 삭제 보호를 켜 두었고 스택을 지워도 남습니다(`Retain`) |
| 비밀값 | Cognito 클라이언트 시크릿은 부팅할 때 인스턴스 역할(`cognito-idp:DescribeUserPoolClient`, 이 User Pool로 한정)로 직접 읽습니다. 쿠키 서명 키는 인스턴스에서 생성합니다. 둘 다 `/etc/oauth2-proxy/secrets.env`(600)에만 있고, 템플릿·파라미터·저장소에는 없습니다 |
| 인스턴스 | IMDSv2 필수(hop limit 1), EBS 암호화, oauth2-proxy는 전용 시스템 사용자로 실행하고 `:80` 바인딩 권한만 가집니다(`ProtectSystem=strict`) |
| 소프트웨어 | code-server와 oauth2-proxy 버전을 파라미터로 고정합니다. oauth2-proxy 압축 파일은 릴리스의 sha256 파일로 무결성을 확인합니다(같은 출처라 위변조 방지는 아닙니다) |

> 로그인하면 `ec2-user` 권한의 셸과 **sudo**를 쓸 수 있습니다. 인스턴스 역할 자격 증명(SSM 관리, 자기 Cognito 클라이언트 읽기)에도 닿을 수 있습니다. 계정은 꼭 필요한 사람에게만 만들어 주세요.

## 개발 환경

### 서버

| 항목 | 값 |
|---|---|
| 인스턴스 | `t4g.large` (Graviton2, 2 vCPU, 8 GiB, 버스터블 standard: 평소 vCPU당 30%, 크레딧이 남아 있으면 100%) |
| OS | Amazon Linux 2023 (arm64) |
| 사용자 | `ec2-user` (sudo 가능), code-server와 SSH 모두 같은 사용자 |
| 디스크 | `/` 30 GiB gp3, `/home` 50 GiB gp3 (XFS, 레이블 `code2-home`) |
| code-server | 4.139.1, `127.0.0.1:8080`, 텔레메트리와 업데이트 확인 끔 |
| 확장 마켓플레이스 | Open VSX (code-server 기본값) |

### 기본 설치 도구

`git`, `python3` (+ `pip`), `gcc`, `make`, `tmux`, `jq`, AWS CLI v2. **Node.js와 Docker는 설치되어 있지 않습니다.**

필요한 도구는 직접 설치합니다. 인스턴스를 교체하면 `/` 아래는 새로 만들어지므로, 오래 쓸 도구는 `/home` 아래에 설치하는 편이 안전합니다.

| 설치 위치 | 예 | 인스턴스 교체 시 |
|---|---|---|
| `/home/ec2-user` (사용자 단위) | `nvm`/`fnm`으로 Node, `uv`/`pipx`로 Python 도구, `~/.local/bin`, 저장소, VS Code 설정과 확장 | **유지** |
| `/` (시스템 단위) | `sudo dnf install nodejs20 python3.12 docker` | 다시 설치해야 함 |

### 쓰는 방법

| 방법 | 방법 |
|---|---|
| 브라우저 | `infra/deploy.sh status`의 URL에서 로그인. 터미널은 `` Ctrl+` `` |
| 개발 서버 미리 보기 | 인스턴스에서 띄운 웹 서버는 `<URL>/proxy/<포트>/` 로 엽니다(로그인 필요). 경로 접두사를 그대로 넘기려면 `/absproxy/<포트>/` 를 씁니다 |
| SSH | `infra/deploy.sh ssh` |
| VS Code Remote-SSH | `infra/deploy.sh ssh-config`가 출력하는 블록을 `~/.ssh/config`에 붙이고, 접속 전에 같은 출력에 있는 `send-ssh-public-key` 명령으로 키를 넣습니다 |
| Session Manager | `infra/deploy.sh shell` (SSH 키 없이 `ssm-user` 셸, sudo 가능) |

GitHub에는 인스턴스에서 `ssh-keygen -t ed25519`로 키를 만든 뒤 계정에 등록해 접근합니다. 키는 `/home`에 있어서 인스턴스를 교체해도 남습니다.

## 운영

저장소 루트에서 실행합니다. 설정은 환경 변수로 줍니다.

| 변수 | 기본값 | 설명 |
|---|---|---|
| `CODE2_ADMIN_EMAIL` | (필수, 첫 배포) | 임시 암호를 받을 메일 |
| `CODE2_ADMIN_USER` | `admin` | 로그인 이름 |
| `CODE2_DOMAIN` | 없음 | 내 도메인. 없으면 CloudFront 주소 |
| `CODE2_ZONE` | 도메인에서 첫 레이블을 뺀 값 | Route 53 호스티드 존 이름 |
| `CODE2_STACK` | `code2` | 스택 이름(소문자, `aws`/`amazon`/`cognito` 포함 불가: Cognito 도메인 접두사로 쓰입니다). 이름을 달리하면 한 계정에 여러 대를 만들 수 있습니다 |
| `CODE2_ACCOUNT` | 없음 | 지정하면 다른 계정의 자격 증명으로는 실행하지 않습니다 |
| `AWS_REGION` | `ap-northeast-2` | 배포 리전 |

| 명령 | 하는 일 |
|---|---|
| `infra/deploy.sh stack plan` | 변경 세트를 만들고 변경 내용만 보여 줍니다. 아무것도 바꾸지 않습니다 |
| `infra/deploy.sh stack apply` | 가장 최근 변경 세트를 실행합니다 |
| `infra/deploy.sh status` | URL, 인스턴스 상태, 서비스 상태, `/home` 사용량, code-server 경로를 보여 줍니다 |
| `infra/deploy.sh ssh [명령]` | EICE를 거쳐 `ec2-user`로 SSH 접속합니다 |
| `infra/deploy.sh ssh-config` | `~/.ssh/config`용 블록을 출력합니다 |
| `infra/deploy.sh shell` | Session Manager 셸을 엽니다 |
| `infra/deploy.sh stop` / `start` | 인스턴스를 중지하거나 시작합니다. 중지하면 사이트는 502를 반환하고, NAT Gateway 요금은 계속 나갑니다 |

인스턴스에서 직접 확인할 때:

```bash
systemctl status code-server oauth2-proxy
journalctl -u oauth2-proxy -n 50        # 로그인 / 콜백 오류
journalctl -u code-server -n 50
sudo cat /var/log/cloud-init-output.log # 첫 부팅(user data) 기록
```

### 계정 추가

```bash
aws cognito-idp admin-create-user --user-pool-id <UserPoolId> --username <이름> \
  --user-attributes Name=email,Value=<메일> Name=email_verified,Value=true
```

모든 계정은 같은 서버의 같은 `ec2-user`로 들어갑니다. 사람마다 따로 환경이 필요하면 `CODE2_STACK`을 달리해 스택을 하나씩 만듭니다.

`CODE2_ADMIN_USER`를 바꾸고 `stack plan`/`apply`를 하면, Cognito는 사용자 이름을 바꿀 수 없으므로 사용자를 새로 만들고(임시 암호 재발송, TOTP 재등록) 이전 사용자는 삭제합니다.

### 주의

- **ImageId는 업데이트할 때도 이전 값을 그대로 씁니다.** AMI가 바뀌면 인스턴스가 교체되는데, 새 인스턴스에 데이터 볼륨을 붙이려 할 때 옛 인스턴스가 아직 볼륨을 잡고 있어 실패합니다. 다시 만들어야 하면 `DataVolumeAttachment`를 먼저 분리한 다음 진행합니다.
- `InstanceType`을 바꾸면 중지 후 시작으로 적용되고, 인스턴스는 교체되지 않습니다.
- user data는 첫 부팅 때만 실행됩니다. code-server나 oauth2-proxy 버전을 올리려면 인스턴스 안에서 직접 설치하고 서비스를 재시작합니다.
- 리전의 첫 번째 AZ를 씁니다. 그 AZ에 고른 인스턴스 타입이나 CloudFront VPC origin이 없으면 다른 리전을 쓰거나 템플릿의 AZ 선택을 바꿉니다.
- EC2 Instance Connect Endpoint는 계정·리전마다 개수 제한(기본 5개)이 있습니다.
- 버스터블 크레딧이 떨어지면 CPU가 vCPU당 30%로 제한됩니다(standard 모드라 추가 요금은 없음). 빌드가 자주 느리면 `m7g.large`로 바꾸는 것을 검토합니다.

### 삭제

```bash
aws cloudformation delete-stack --stack-name code2
```

- `/home` 볼륨은 스냅샷으로 남습니다. 필요 없으면 EC2 콘솔에서 지웁니다.
- User Pool은 남습니다(`Retain`, 삭제 보호). 지우려면 삭제 보호를 끈 다음 삭제합니다.
  ```bash
  aws cognito-idp update-user-pool --user-pool-id <UserPoolId> --deletion-protection INACTIVE
  aws cognito-idp delete-user-pool --user-pool-id <UserPoolId>
  ```
- CloudFront가 VPC에 만든 `CloudFront-VPCOrigins-Service-SG`가 늦게 지워져 VPC 삭제가 실패하면, 잠시 뒤 다시 삭제합니다.

## 저장소 구성

```
code2/
├── README.md
├── docs/            구성도 (아래)
└── infra/
    ├── code2.yaml   CloudFormation: VPC·NAT·EICE, Cognito, EC2·EBS, CloudFront VPC origin, (선택) Route 53
    └── deploy.sh    change set plan/apply, status, ssh, ssh-config, shell, stop/start
docs/
├── architecture.png   README 구성도
└── architecture.svg   구성도 원본 (아이콘 포함, 브라우저·Inkscape·draw.io에서 편집)
```

## 예상 비용 (서울, 월, 대략)

| 항목 | 금액 |
|---|---|
| EC2 t4g.large (24시간 상시) | 약 $61 |
| NAT Gateway (시간 요금, 데이터 $0.059/GB 별도) | 약 $43 |
| 공인 IPv4 (NAT EIP) | 약 $3.6 |
| EBS gp3 30 + 50 GiB | 약 $7 |
| CloudFront, Cognito(Essentials 무료 구간), EICE, Route 53 | 약 $1 미만 |
| **합계** | **약 $115** |

인스턴스를 중지하면 EC2 요금(약 $61)은 나가지 않지만, NAT Gateway·IPv4·EBS 요금은 계속 나갑니다. 요금은 리전과 시점에 따라 다르니 [AWS 요금 계산기](https://calculator.aws/)로 확인합니다.

## 라이선스

[MIT](LICENSE)
