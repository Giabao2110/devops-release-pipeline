# Ghi chú học và chuẩn bị phỏng vấn — devops-release-pipeline

Tài liệu này dành cho Bảo. Mục đích là để Bảo tự giải thích được từng phần của
repo khi phỏng vấn Ather Labs (DevOps Engineer). Nên đọc kèm code: mỗi mục đều
ghi tệp cần mở.

> Nguyên tắc khi trình bày: đây là **lab cá nhân**, không phải production. Kinh
> nghiệm thật trên server là phần ở Bubobot (case study). Lab là nơi Bảo tái
> hiện ý tưởng đó bằng Kubernetes, AWS IaC, ký artifact và đo chỉ số.

---

## 0. Câu giới thiệu 60 giây (gợi ý)

> "Ở Bubobot em làm workflow GitHub Actions + Bash để deploy lên staging, có
> canary, health check và tự rollback. Em cũng cấu hình Prometheus, Alertmanager
> và Grafana. Để bù phần Kubernetes và AWS mà JD yêu cầu, em làm một lab cá nhân:
> app Go nhỏ đi qua pipeline gồm test, build 4 nền tảng có checksum, image đa
> kiến trúc ký bằng cosign, deploy lên cụm kind ngay trong CI. Smoke test hỏng
> thì `rollout undo` tự động. Prometheus/Grafana theo dõi cả app lẫn tỉ lệ
> rollback. Terraform mô tả VPC, EC2, S3 có versioning và IAM tối thiểu; em chỉ
> chạy validate/plan, không apply. Em tập hai lần deploy hỏng; cả hai đều tự
> quay về bản cũ, không mất request nào."

Chỉ nói những gì đã chạy thật. Xem bảng "Đã/chưa kiểm chứng" ở cuối.

---

## 1. App Go (`app/`)

- **Làm gì:** HTTP server chỉ dùng thư viện chuẩn của Go.
  - `/healthz` (liveness), `/readyz` (readiness), `/version` (thông tin build).
  - `/metrics` theo định dạng Prometheus, `/api/work` (endpoint giả lập công việc).
- **Vì sao tự viết `/metrics`, không dùng thư viện?** Không có dependency bên
  ngoài nên build tái lập được, không có rủi ro supply chain. File `metrics.go`
  có counter, gauge và histogram cơ bản. Production thì nên dùng
  `client_golang`, câu này nên nói rõ khi được hỏi.
- **Liveness và readiness khác nhau:**
  - Liveness hỏi "process còn sống không?"; hỏng thì kubelet **restart** container.
  - Readiness hỏi "nhận traffic được chưa?"; hỏng thì pod bị **gỡ khỏi Service**, không restart.
  - Khi nhận SIGTERM, app tắt readiness trước, chờ vài giây rồi mới shutdown. Nhờ vậy request đang chạy không bị cắt (`main.go`).
- **Fault injection:** biến môi trường để tập sự cố.
  - `FAIL_MODE=unhealthy`: probe trả 503.
  - `FAIL_MODE=crash`: thoát ngay, gây CrashLoopBackOff.
  - `ERROR_RATE=0.2`: 20% request lỗi 500.
- **Version nhúng lúc build:** `-ldflags "-X main.version=..."`. Nhờ vậy `/version` cho biết chính xác bản nào và commit nào đang chạy.
- **Test:** `server_test.go`, `metrics_test.go` (table-driven test, giả lập random để test lỗi). Coverage 78%.

## 2. Dockerfile

- **Multi-stage:** stage 1 dùng `golang:alpine` để compile binary tĩnh
  (`CGO_ENABLED=0`). Stage 2 chỉ copy binary vào `distroless/static:nonroot`,
  không có shell hay package manager. Image 15 MB.
- **Non-root:** `USER 65532`. Manifest K8s còn bật thêm:
  - `runAsNonRoot` và `readOnlyRootFilesystem`;
  - `allowPrivilegeEscalation: false` và drop mọi capability;
  - namespace bật Pod Security `restricted`.
- **`--platform=$BUILDPLATFORM` + `TARGETARCH`:** compile chéo sang arm64 mà
  không cần giả lập toàn bộ build, nên buildx đa kiến trúc chạy nhanh hơn.

## 3. Version, đóng gói, checksum (`scripts/version.sh`, `package.sh`)

- **Version theo git tag:**
  - commit đúng tag `v1.4.0` → `1.4.0`;
  - sau tag 3 commit → `1.4.0-dev.3+abc1234` (semver pre-release + build metadata);
  - chưa có tag → `0.0.0-dev.N+sha`.
- Docker tag không cho dấu `+`, nên có thêm `IMAGE_TAG` thay `+` bằng `-`.
- **Đóng gói:** mỗi nền tảng ra một `tar.gz` (Windows là `zip`), kèm
  `BUILD_INFO.json` và một file `.sha256`. Lúc release gộp thành `SHA256SUMS`;
  người tải chạy `sha256sum -c` để biết file không bị hỏng hay bị tráo.
- **Liên hệ game build (điểm cộng của JD):** một mã nguồn ra nhiều artifact
  theo nền tảng, mỗi artifact có version, checksum, chữ ký. Unity/Unreal cũng
  vậy, chỉ khác là build nặng hơn.

## 4. Ký bằng cosign keyless

- **Vấn đề:** checksum chỉ chứng minh file không đổi so với *checksum*. Nếu kẻ
  xấu tráo cả file lẫn checksum thì sao? Phải có **chữ ký** gắn với danh tính
  người build.
- **Keyless:** không lưu private key. Khi job GitHub Actions chạy:
  - nó lấy một OIDC token (cần `permissions: id-token: write`);
  - Sigstore (Fulcio) cấp chứng chỉ ngắn hạn ghi danh tính "workflow `ci.yml` của repo này";
  - chữ ký được ghi vào transparency log (Rekor).
- **Ký theo digest, không theo tag:** tag (`:latest`) có thể bị đẩy sang image
  khác, còn digest `sha256:...` là nội dung cố định.
- **Verify:** `cosign verify` với `--certificate-identity-regexp` (đúng repo và
  workflow) và `--certificate-oidc-issuer` (GitHub). Release thì ký file
  `SHA256SUMS` bằng `cosign sign-blob --bundle`.
- **Trung thực:** phần này chỉ chạy được trên GitHub Actions. Xem trạng thái CI
  ở cuối tài liệu.

## 5. GitHub Actions (`.github/workflows/ci.yml`)

Thứ tự: `test` và `iac` song song → `version` → `build` (matrix 4 nền tảng),
`image`, `deploy-kind` song song → `metrics` (luôn chạy) → `release` (chỉ khi push tag `v*`).

- `permissions: contents: read` ở mức workflow. Job nào cần thêm quyền mới khai
  báo, ví dụ `packages: write` để push GHCR hay `id-token: write` để ký. Đây là least privilege.
- `concurrency`: PR mới hủy lần chạy cũ của cùng PR.
- PR thì build image nhưng **không push, không ký** vì PR từ fork không được giữ token ghi.
- `metrics` dùng `if: always()` để vẫn báo cáo khi job khác hỏng; số liệu lỗi
  cũng là số liệu.

## 6. Kubernetes (`deploy/k8s/`)

- **Kustomize:** `base/` chứa manifest chung, `overlays/kind/` thay image. kubectl có sẵn Kustomize (`kubectl apply -k`).
- **Deployment, các trường quan trọng:**
  - `replicas: 2`; `maxSurge: 1`, `maxUnavailable: 0`: luôn đủ 2 pod phục vụ,
    pod mới phải Ready thì pod cũ mới bị gỡ. Cách này giống canary một pod.
  - `progressDeadlineSeconds: 60`: quá 60 giây không tiến triển thì rollout bị đánh dấu thất bại.
  - `revisionHistoryLimit: 5`: giữ ReplicaSet cũ để `rollout undo` có chỗ quay về.
  - `resources.requests/limits`: request dùng để scheduler xếp pod; vượt limit
    memory thì bị OOMKill, vượt limit CPU thì bị throttle.
- **Service:** chọn pod bằng label (selector). Sai label thì không có endpoint (bài 02).
- **HPA:** scale 2–5 pod theo CPU 70%. Cần metrics-server, mà kind không cài
  sẵn, nên HPA báo `<unknown>`. Nói thẳng điều này.
- **PDB `minAvailable: 1`:** khi drain node, luôn còn ít nhất một pod.

## 7. Deploy và rollback (`scripts/deploy.sh`)

1. `kubectl patch` đổi image, label version và annotation `change-cause`, tạo ra một ReplicaSet mới.
2. `kubectl rollout status --timeout=90s`: chờ rolling update; readiness probe chặn pod lỗi.
3. `smoke_test.sh` đi qua **Service**: `/healthz`, `/readyz`, `/metrics` và `/version` phải đúng bản mới.
4. Hỏng ở bước 2 hoặc 3 thì in chẩn đoán (pods, events), rồi `kubectl rollout undo`, chờ, và smoke test lại bản cũ.
5. Ghi một dòng JSON vào `.state/deploy-events.jsonl`, rồi đẩy counter lên Pushgateway nếu có.
6. Exit code: 0 = thành công, 3 = hỏng nhưng đã rollback, 4 = rollback cũng hỏng (cần người xử lý).

**Kết quả thật trên máy (16/11):**

- Bản hỏng `FAIL_MODE=unhealthy`: rollout timeout sau 60 giây, undo, bản 1.1.0 được kiểm tra lại, exit 3.
- Bản `FAIL_MODE=crash` chạy trong lúc load test: pod mới CrashLoopBackOff, rollback, **496 request không request nào lỗi**.

**Chi tiết hay bị hỏi:** sau `rollout undo`, revision cũ (2) được đánh số lại
thành revision mới (4). Lý do là Kubernetes tái sử dụng ReplicaSet cũ và tăng
revision.

## 8. Monitoring (`deploy/monitoring/`)

- **Prometheus:**
  - dùng `kubernetes_sd_configs` (role pod) để tự tìm pod có annotation `prometheus.io/scrape: "true"`;
  - gắn label `pod` và `release` (version) vào series;
  - RBAC chỉ có quyền get/list/watch.
- **Pushgateway:** dành cho job ngắn như deploy script. Script đẩy
  `release_deployments_total{result=...}` cùng thời gian và kết quả của lần deploy cuối.
- **Grafana:** datasource và dashboard được provision từ file (dashboard as
  code), không click tay. Dashboard gồm pod ready, version đang chạy, số lần
  deploy, tỉ lệ rollback, req/s theo status code, tỉ lệ 5xx, p50/p95 latency,
  traffic theo release.
- **5 alert rule** (`alerts.yml`):
  - `ReleaseDemoDown`: không target nào up, kéo dài 2 phút.
  - `ReleaseDemoHighErrorRate`: 5xx > 5% trong 5 phút.
  - `ReleaseDemoHighLatencyP95`: p95 > 500 ms trong 10 phút.
  - `DeploymentRolledBack`: counter rollback tăng.
  - `RollbackRateHigh`: hơn 30% deploy phải rollback, khi đã có ít nhất 3 lần deploy.
- **Test alert:** `promtool test rules alerts_test.yml` tạo chuỗi số liệu giả
  rồi kiểm tra alert bật đúng lúc (sau `for`) và không bật khi traffic khỏe.
- **`for: 5m` để làm gì?** Tránh báo động vì một đợt lỗi ngắn (flapping).
- **Công thức cần thuộc:**
  - tỉ lệ lỗi: `sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`;
  - p95: `histogram_quantile(0.95, sum by (le) (rate(..._bucket[5m])))`.

## 9. Chỉ số pipeline (`scripts/pipeline_metrics.py`)

- `builds`: thời gian build từng nền tảng, kích thước, tỉ lệ build lỗi.
- `jobs`: thời gian từng job của lần chạy hiện tại, lấy từ GitHub API.
- `runs`: tỉ lệ lỗi và thời gian trung bình/p90 của 50 lần chạy gần nhất (`gh run list`). Không tính lần bị cancel.
- `deploys`: số lần deploy, tỉ lệ rollback, thời gian deploy. `--prom` xuất định dạng Prometheus cho Pushgateway.
- Có 8 unit test kèm fixture.
- Liên hệ JD "theo dõi thời gian build, tỉ lệ lỗi, rollback": ba chỉ số đó nằm ở đây và trên dashboard.

## 10. Terraform AWS (`infra/terraform/aws/`)

| Tệp | Nội dung | Điểm cần giải thích |
|---|---|---|
| `network.tf` | VPC /16, 2 subnet public ở 2 AZ, IGW, route table, SG | Không NAT vì NAT tính phí theo giờ. SG chỉ mở 8080 cho `allowed_cidr`, có validation chặn `0.0.0.0/0`, không mở SSH |
| `compute.tf` | EC2 t3.micro AL2023 | Bắt buộc IMDSv2 (`http_tokens = required`), ổ gp3 mã hóa. Truy cập bằng SSM, không SSH key. `user_data` chạy container qua systemd |
| `storage.tf` | S3 bucket artifact | Bật versioning; chặn public; mã hóa SSE; chỉ cho HTTPS. Lifecycle: `builds/` xóa sau 14 ngày, `releases/` chuyển sang STANDARD_IA sau 30 ngày, version cũ xóa sau 30 ngày, hủy multipart dở dang |
| `iam.tf` | Role EC2 + role CI | EC2 chỉ được đọc `releases/*`. CI dùng **GitHub OIDC**, không có access key. Trust policy chỉ cho repo này với nhánh main hoặc tag `v*`; quyền chỉ `PutObject` vào `builds/*` và `releases/*` |
| `providers.tf` | `offline_plan` | Plan không cần tài khoản AWS (key giả, bỏ kiểm tra credential). Chỉ để review, **không apply** |

Kết quả: `fmt -check` OK, `validate` OK, `plan` ra **26 resource to add**.
Chưa apply nên chưa có tài nguyên thật nào.

EKS chưa làm vì control plane tốn khoảng 0,10 USD/giờ. Nếu được hỏi thì nói
hướng làm: thêm private subnet + NAT hoặc VPC endpoint, module EKS, node group,
dùng IRSA hoặc Pod Identity để pod nhận quyền IAM.

## 11. Ba bài troubleshoot (`docs/troubleshooting/`)

1. **CrashLoopBackOff:** đọc `describe pod` (Last State, Exit Code 1), rồi `logs --previous`, tìm thấy env sai, sửa.
2. **Selector sai:** pod Running nhưng Service không có endpoint. So `svc.spec.selector` với label của pod, rồi patch selector.
3. **Grafana OOMKilled (sự cố thật trong lúc làm lab):**
   - triệu chứng: exit 137, limit 256Mi;
   - log cho thấy Grafana tự tải plugin lúc khởi động;
   - cách sửa: tắt preinstall plugin, nâng limit lên 512Mi.

Quy trình chung khi pod lỗi:
`get pods` → `describe` (Events, Last State) → `logs --previous` → `get endpointslices` → so sánh với revision trước.

---

## 12. Mười câu hỏi phỏng vấn mẫu và gợi ý trả lời

**1. Rolling update khác canary và blue-green thế nào? Lab của bạn dùng cái gì?**
- **Rolling:** thay dần từng pod.
- **Canary:** đưa một phần nhỏ traffic sang bản mới trước rồi mới mở rộng.
- **Blue-green:** chạy song song hai môi trường và chuyển traffic một lần.
- **Lab:** rolling với `maxSurge 1 / maxUnavailable 0`, gần giống canary một pod: pod mới phải Ready mới tiếp tục. Không chia traffic theo phần trăm; muốn vậy phải dùng Argo Rollouts hoặc service mesh.
- **Ở Bubobot:** canary trên một instance VM trước.

**2. Khi nào pipeline của bạn rollback, và làm sao biết rollback thành công?**
- Rollback khi rollout không Ready trong thời hạn, hoặc khi smoke test qua Service hỏng.
- Biết thành công vì sau `rollout undo`, script chờ rollout xong rồi smoke test lại bản cũ. Exit code 3 nghĩa là đã rollback an toàn, 4 nghĩa là rollback cũng hỏng.
- Lần tập thật: 0/496 request lỗi.

**3. Readiness và liveness probe khác nhau? Cấu hình sai thì sao?**
- Readiness hỏng: pod bị gỡ khỏi Service. Liveness hỏng: container bị restart.
- Liveness quá gắt, ví dụ timeout ngắn hay kiểm tra cả database, sẽ restart liên tục và làm sự cố nặng hơn.
- Không có readiness thì traffic đổ vào pod chưa sẵn sàng.

**4. Pod bị CrashLoopBackOff, bạn xử lý thế nào?**
- Kể đúng bài 01: describe (exit code), `logs --previous`, xem thay đổi gần nhất, rollback trước rồi sửa nguyên nhân sau.
- Phân biệt với OOMKilled (exit 137) và ImagePullBackOff.

**5. Bạn quản lý version và đảm bảo artifact không bị tráo như thế nào?**
- Semver từ git tag + commit SHA nhúng vào binary và image.
- Checksum SHA-256 cho từng file, gộp thành `SHA256SUMS`.
- Ký cosign keyless theo digest; verify bằng danh tính workflow và OIDC issuer.
- Ký theo digest vì tag có thể bị đẩy sang image khác.

**6. Keyless signing là gì, tại sao tốt hơn lưu private key trong secrets?**
- Không có key dài hạn để bị lộ.
- Chứng chỉ ngắn hạn gắn với danh tính workflow. Chữ ký nằm trong transparency log nên kiểm toán được.
- Đánh đổi: phụ thuộc hạ tầng Sigstore, và bản ký công khai danh tính repo.

**7. Theo dõi sức khỏe của pipeline bằng chỉ số nào?**
- Thời gian build từng nền tảng, thời gian từng job.
- Tỉ lệ lỗi trên 50 lần chạy gần nhất (bỏ lần cancel).
- Số lần deploy, tỉ lệ rollback, thời gian deploy.
- Có alert khi có rollback và khi tỉ lệ rollback trên 30%.
- Liên hệ DORA: deployment frequency, change failure rate, MTTR.

**8. Alert tốt khác alert gây nhiễu thế nào?**
- Alert dựa trên triệu chứng người dùng thấy: tỉ lệ lỗi, latency, mất dịch vụ.
- Có `for` để chống flapping, có severity, có annotation hướng dẫn.
- Có test cho cả trường hợp **không** được bật.
- Ở Bubobot em kiểm tra rule bằng promtool và gửi cảnh báo qua Alertmanager vào Discord.

**9. Giải thích Terraform AWS của bạn. Vì sao không apply?**
- Đi qua bảng ở mục 10.
- Không apply vì đây là lab cá nhân, tránh chi phí và rủi ro. Plan offline đủ để review thay đổi.
- Nếu apply thật: dùng state backend S3 có lock, tách môi trường, chạy plan trong PR, apply có duyệt, và `destroy` ngay sau khi demo.

**10. Bạn dùng AI trong công việc DevOps thế nào?**
- Dùng để soạn nháp script, workflow, tài liệu và gợi ý hướng debug.
- Luôn kiểm chứng: chạy test, shellcheck, promtool, chạy thử trên kind hoặc staging.
- Ví dụ thật: lỗi CRLF khi đẩy metric từ Windows, và Grafana OOMKill. Cả hai chỉ lộ ra khi chạy thật, không phải lúc đọc code.
- JD có ghi ưu tiên kỹ năng dùng AI cho script, debug và tài liệu.

---

## 13. Đã và chưa kiểm chứng (cập nhật 16/11/2026)

| Phần | Trạng thái |
|---|---|
| Go test, Python test, shellcheck, promtool | Đã chạy trên máy, qua |
| Docker build, image non-root | Đã chạy |
| kind: bootstrap, deploy, 2 lần rollback, 2 bài troubleshoot | Đã chạy, log ở `docs/evidence/` |
| Prometheus/Grafana/Pushgateway trên kind, alert rollback firing | Đã chạy, có ảnh dashboard |
| Build 4 nền tảng + checksum (local) | Đã chạy |
| Terraform fmt/validate/plan offline | Đã chạy; **chưa apply** |
| GitHub Actions, GHCR, cosign keyless | Chỉ chạy khi repo lên GitHub; xem `docs/evidence/README.md` |
| HPA scale thật | Chưa (thiếu metrics-server) |
| EKS, AWS thật | Chưa làm |

Trước phỏng vấn nên tự chạy lại phần "Run it locally" trong README ít nhất một
lần, và tự gõ lại bài troubleshoot 01 mà không nhìn tài liệu.
