# ticket-rush-deploy

배포 전용 워크스페이스.

- 애플리케이션 코드 CI/CD와 분리
- AWS 인프라(Terraform) + 런타임(Compose) + 운영 스크립트 포함
- 문서성 회의록/태스크는 sidecar(`aki-agentops/prj-docs`)에서 관리

## Layout

- `deploy/aws/terraform`: EC2/보안그룹/IAM 인프라 코드
- `deploy/aws/docker-compose/ticket-rush`: EC2 런타임 스택 정의
- `deploy/aws/scripts`: 원격 배포/롤백 스크립트
  - `Caddy`를 통해 `80/443` TLS 종단 처리

## Deployment Flow

1. 프로젝트 CI(GitHub Actions)에서 백엔드/프론트 이미지를 ECR에 push
2. Terraform으로 EC2 1대(`t3.small`) 생성
3. 배포 스크립트로 EC2에서 compose pull/up
   - 기본: SSM mode(키페어 불필요)
   - 선택: SSH mode(키페어 사용)
   - 도메인 기본값: `goopang.shop` (`--app-domain`으로 변경 가능)

## Notes

- 포트폴리오 저트래픽 기준 단일 인스턴스 구성
- `APP_SEED_KPOP20_ENABLED`는 기본 `true`로 배포 스크립트에서 전달됨
  - 최초 데이터 생성 이후 `false`로 재배포 권장
- Terraform 기본값은 `enable_ssh=false`, `key_name=""`로 키페어 없이 배포 가능
- HTTPS는 DNS 위임 완료 후 Caddy가 자동 인증서 발급/갱신 처리
