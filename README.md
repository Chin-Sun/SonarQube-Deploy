# SonarQube on 阿里云 + 自建 GitLab（MR 质量门禁）部署包

按此包在阿里云 ECS 上用 Docker 跑 SonarQube Community Build + 分支插件，元数据库接 RDS PostgreSQL，
实现 GitLab：push → 开 MR → 自动扫描本次改动 → 质量门不过则阻止合并。

完整方案见计划文件：`~/.claude/plans/sonarqube-*.md`。

## 文件清单
| 文件 | 放哪 | 作用 |
|---|---|---|
| `.env.example` | SonarQube 主机（ECS） | 复制成 `.env` 填变量；**钉死** SonarQube 与插件版本 |
| `docker-compose.yml` | ECS | 启动 SonarQube + 自动下载分支插件，连 RDS |
| `host-setup.sh` | ECS | root 跑一次，设 `vm.max_map_count` 等内核参数 |
| `project-template/.gitlab-ci.yml` | **被检查项目**仓库根 | MR/默认分支触发扫描，门失败即流水线失败 |
| `project-template/sonar-project.properties` | **被检查项目**仓库根 | projectKey / 源码范围 |

## 部署顺序速查
1. **开资源**：同 VPC 建 ECS（4C16G，挂 ESSD 数据盘）+ RDS PostgreSQL（建库 `sonarqube`/账号 `sonar`，ECS 加入白名单，用内网地址）。ECS 绑 EIP。
2. **主机准备**：`sudo bash host-setup.sh`；装 Docker + compose 插件。
3. **配置**：`cp .env.example .env` 填 RDS 与版本 → `docker compose up -d` → `docker compose logs -f sonarqube` 等到 `SonarQube is operational`。
4. **SonarQube 配置**：访问 `http://<EIP>:9000`，`admin/admin` 改密 → 生成 Analysis Token →
   Administration → DevOps Platform Integration → **GitLab**：填 `https://<你们GitLab域名>/api/v4` + 一个机器人账号的 **PAT(api scope)** → 设默认 Quality Gate（条件作用于 **New Code**）。
5. **GitLab 项目**：Settings → CI/CD → Variables 加 `SONAR_HOST_URL`、`SONAR_TOKEN`（Masked/Protected）；
   把 `project-template/` 两个文件拷进项目根并改 `projectKey`。
6. **打开拦截**：项目 Settings → Merge requests 勾 **Pipelines must succeed**；Repository → Protected branches 保护主分支、禁止直推。

## 验证（四步）
- 主分支跑一次流水线 → SonarQube 出现项目与门结果。
- 合规改动开 MR → job 通过、MR 收到 SonarQube 装饰评论 → 可合并。
- 故意制造门失败的改动 → job 失败 → 合并被拦 → 修复后重跑通过 → 可合并。
- 确认门只判 New Code（历史问题不卡新 MR）。

## 关键注意
- **版本钉死**：插件 `X.Y.Z` 必须配 SonarQube `X.Y.x`（`.env` 里同步改）。升级 SonarQube 前先在测试环境验证插件兼容。
- **部分插件版本**还需替换 web 目录（参见插件 README 安装说明）；若你选的版本要求如此，改用 Dockerfile 方案在镜像内 COPY 插件 jar 与 webapp 覆盖包。
- **网络双向通**：GitLab Runner 要能访问 SonarQube；SonarQube 要能访问 GitLab API（出站 443）。
- **安全组**：9000/SSH 入站按来源 IP 白名单，勿对 0.0.0.0/0 开放。
- 生产化：前置 ALB/Nginx 上 HTTPS、RDS 高可用+备份、ECS 数据盘快照。

参考：
- https://www.sonarsource.com/products/sonarqube/deployment/
- https://github.com/mc1arke/sonarqube-community-branch-plugin
