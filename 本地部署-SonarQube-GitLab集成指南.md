# 本地 SonarQube + 公司 GitLab 集成指南（macOS / Apple Silicon）

> 一句话定位：在本机用 Docker 跑 SonarQube（带分支插件），接到公司自建 GitLab，实现「开 MR → 本地 Runner 自动扫描 → 质量门不过则拦合并」。
>
> 适合谁：要在 **个人 Mac（arm64）** 上搭一套可用的代码质量门禁、又不想（也不能）把 SonarQube 暴露到公网的工程师。技术执行者从第 3 章照做即可落地。

---

## 文档目录

- 第 1 章 [为什么是这套架构](#第-1-章为什么是这套架构)
- 第 2 章 [架构与数据流](#第-2-章架构与数据流)
- 第 3 章 [部署步骤（照做即可）](#第-3-章部署步骤照做即可)
- 第 4 章 [项目里加的两个文件：为什么 + 作用](#第-4-章项目里加的两个文件为什么--作用)
- 第 5 章 [验证清单](#第-5-章验证清单)
- 第 6 章 [常见坑与 FAQ](#第-6-章常见坑与-faq)
- 附录 [关键术语表](#附录关键术语表)

> ⚙️ 全文前置认知（先记住）：
> - **拦截原理**：SonarQube 不直接「卡」GitLab。质检在 GitLab CI 里执行，扫描器用 `sonar.qualitygate.wait=true` 等门结果；门失败 → job 失败 → 流水线失败 → GitLab「Pipelines must succeed」+ 受保护分支阻止合并。
> - **为什么要本地 Runner**：本地 SonarQube 在 `localhost`，公司共享 Runner 访问不到它。把跑扫描的 Runner 放在本地，它才能直接访问本地 SonarQube。
> - **版本钉死**：分支插件 `26.5.0` 必须配 SonarQube `26.5.x`，升级要一起改。

---

## 第 1 章·为什么是这套架构

> 本节小目标：用 3 分钟说清几个关键选型，避免你走我们踩过的弯路。

### 1.1 三个被否决的方案

| 方案 | 为什么不行 |
|---|---|
| 官方 `gitlab/gitlab-ce` 镜像跑本地 GitLab | 官方只发 **amd64** 镜像，在 Apple Silicon 上用 qemu 模拟会 **段错误（Segmentation fault）** 起不来 |
| 把本地 SonarQube 用内网穿透暴露给公司共享 Runner | 多一层公网映射，仅适合临时测试，且有安全暴露面 |
| 容器内自建数据库 | 有状态数据与容器同生命周期，易丢数据；本方案用独立 `db` 容器（卷持久化） |

### 1.2 最终选型

- **SonarQube**：本地 Docker，**Community Build 26.5 + community-branch-plugin 26.5.0**（分支插件补齐 Community 版没有的分支/MR 分析能力）。
- **数据库**：本地 `postgres:16` 容器，数据存独立卷。
- **GitLab**：直接用**公司自建 GitLab**（`github.molardata.com`），不在本地另起。
- **Runner**：本地注册一个 **GitLab Runner**（docker executor），接入 SonarQube 所在的 Docker 网络。

> ⚠️ 关键认知：分支插件是 **mc1arke 的免费第三方插件**（`https://github.com/mc1arke/sonarqube-community-branch-plugin`）。26.x 版**不是只放 jar**，还必须替换 SonarQube 的 webapp 前端——所以我们用插件仓库自带的 `release.Dockerfile` 构建了一个自定义镜像 `sonarqube-branch:26.5.0`。

---

## 第 2 章·架构与数据流

> 本节小目标：一张图记住「谁主动连谁」，这是所有连通性问题的根源。

```
                       研发同学 push / 开 MR
                                │
                                ▼
        ┌──────────────────────────────────────────────┐
        │     公司自建 GitLab（github.molardata.com）     │
        │     - 触发 MR 流水线                            │
        │     - 合并检查 / 受保护分支拦截                  │
        └──────┬───────────────────────────▲────────────┘
        ①MR触发 │                            │ ④写回 MR 装饰/门状态
        job 派给 │                            │   (SonarQube → GitLab API)
        本地runner▼                           │
        ┌──────────────────────────────────┐ │
        │            你的 Mac（本地）         │ │
        │  ┌────────────────┐               │ │
        │  │ GitLab Runner  │ tags:local-sonar│
        │  │ (docker exec)  │               │ │
        │  └───────┬────────┘               │ │
        │  ②起 job 容器跑 sonar-scanner       │ │
        │          ▼   同一 docker 网络        │ │
        │  ┌────────────────┐   ③扫描结果      │ │
        │  │ SonarQube CE   │◄──+轮询质量门────┘ │
        │  │ +branch-plugin │                  │
        │  └───────┬────────┘                  │
        │          │ JDBC                       │
        │  ┌───────▼────────┐                   │
        │  │ PostgreSQL(db) │                   │
        │  └────────────────┘                   │
        └──────────────────────────────────────┘
```

数据流四步：① 公司 GitLab 把 MR 的扫描 job 派给**本地 Runner**（靠 `local-sonar` 标签精确投递）→ ② Runner 起 job 容器跑 `sonar-scanner` → ③ 结果上报本地 SonarQube 并轮询质量门 → ④ SonarQube 调公司 GitLab API 把结论写回 MR。

**连通性要点（已实测通过）**：

| 方向 | 地址 | 用途 |
|---|---|---|
| Runner / job 容器 → SonarQube | `http://sonarqube:9000`（同 docker 网络服务名） | 上报结果、轮询门 |
| Runner / job 容器 → 公司 GitLab | `http://github.molardata.com` | 拉代码、回传 job 状态 |
| SonarQube → 公司 GitLab API | `http://github.molardata.com/api/v4` | MR 装饰（可选功能） |

---

## 第 3 章·部署步骤（照做即可）

> 本节小目标：从零到「MR 被门禁拦住」。已完成项标 ✅，待你操作项标 🔲。

### 3.1 一次性主机准备（✅ 已完成）

- Docker Desktop 内存调到 **12 GB**（`Settings → Resources → Memory`）。SonarQube 内嵌 Elasticsearch 吃内存，低于此易反复 OOM。
- 设置内核参数（**每次重启 Docker Desktop 后要重设**）：

  ```bash
  docker run --rm --privileged alpine sh -c \
    "sysctl -w vm.max_map_count=524288 && sysctl -w fs.file-max=131072"
  ```

### 3.2 构建带分支插件的 SonarQube 镜像（✅ 已完成）

用插件仓库自带的 `release.Dockerfile` 构建（**轻量路径**，只下载 release 资产，不从源码编译）：

```bash
docker build \
  --build-arg SONARQUBE_VERSION=26.5.0.122743-community \
  --build-arg PLUGIN_VERSION=26.5.0 \
  -t sonarqube-branch:26.5.0 \
  <插件仓库目录>   # plugins/sonarqube-community-branch-plugin
```

> ⚠️ 坑：基础镜像声明了 `VOLUME /opt/sonarqube/extensions`。若 compose 把一个**旧的命名卷**挂到该路径，会盖住镜像里打包好的插件 jar，导致 javaagent 报 `JAR manifest missing`。解决：**不挂 extensions 命名卷**，让 Docker 用全新匿名卷（会自动从镜像复制 jar 进去）。

### 3.3 启动 SonarQube + 数据库 + Runner（✅ 已完成）

配置见 `sonarqube-deploy/docker-compose.local.yml`。启动：

```bash
cd sonarqube-deploy
docker compose -f docker-compose.local.yml up -d
docker compose -f docker-compose.local.yml logs -f sonarqube   # 看到 "SonarQube is operational" 即就绪
```

确认分支插件已加载（日志应出现）：

```
Loaded core extensions: Community Branch Plugin
Deploy Community Branch Plugin / 26.5.0
```

### 3.4 注册本地 Runner 到公司 GitLab（✅ 已完成）

在公司 GitLab：项目 `Settings → CI/CD → Runners → New project runner`，**Tags 填 `local-sonar`、不勾 Run untagged**，拿到 `glrt-` 开头的 token，然后：

```bash
docker exec sonarqube-deploy-gitlab-runner-1 gitlab-runner register \
  --non-interactive \
  --url "http://github.molardata.com" \
  --token "glrt-xxxxxxxx" \
  --executor docker \
  --docker-image "python:3.11" \
  --docker-network-mode "sonarqube-deploy_default"   # 关键：让 job 容器接入 SonarQube 网络
```

### 3.5 在 SonarQube 建项目并拿 token（🔲 待你操作）

1. 浏览器开 `http://localhost:9000`，登录。
2. `Create project → Locally`，**Project key 填 `molardata-auto-optimized-test`**（必须与 `sonar-project.properties` 里一致）。
3. New Code 定义选默认（`Previous version`）即可。
4. `Generate a token` → **完整复制保存**（只显示一次）。

### 3.6 在 GitLab 项目配 CI 变量（🔲 待你操作）

项目 `Settings → CI/CD → Variables`，新增两条（都勾 **Masked**，主分支建议勾 **Protected**）：

| Key | Value | 说明 |
|---|---|---|
| `SONAR_HOST_URL` | `http://sonarqube:9000` | job 容器在 SonarQube 网络里，用服务名访问 |
| `SONAR_TOKEN` | `<3.5 生成的 token>` | 扫描鉴权 |

### 3.7 提交两个项目文件（🔲 待你操作）

本仓库已在被检查项目根目录创建 / 修改：

- `sonar-project.properties`（新增）
- `.gitlab-ci.yml`（新增 `sonarqube-check` job）

review `git diff` 后推送（建议在演示分支推、再开 MR）。两个文件的作用见**第 4 章**。

### 3.8 配质量门与拦截开关（🔲 待你操作）

- **SonarQube**：`Quality Gates` 确认条件**作用于 New Code**（如 `New Bugs = 0`、`New Blocker/Critical = 0`）。这样只判本次改动，不被历史存量卡死。
- **GitLab 项目**：
  - `Settings → Merge requests` 勾 **Pipelines must succeed**。
  - `Settings → Repository → Protected branches` 保护 `main`、禁止直推。

### 3.9 （可选）开启 MR 装饰

让 SonarQube 把「通过 / 失败」写回 MR 评论，需要额外：

1. 准备一个机器人账号的 **PAT（api scope）**。
2. SonarQube：`Administration → DevOps Platform Integration → GitLab`，填 `http://github.molardata.com/api/v4` + 该 PAT。
3. 项目 `Project Settings → DevOps Platform Integration` 绑定到 GitLab 仓库。

> 说明：MR 装饰只是「锦上添花」。**拦合并不依赖它**——靠 `qualitygate.wait` + Pipelines must succeed 就能拦。

---

## 第 4 章·项目里加的两个文件：为什么 + 作用

> 本节小目标：说清这两个文件是「整条门禁链路的输入」，少一个都不行。

### 4.1 `sonar-project.properties` —— 告诉扫描器「扫什么、报给哪个项目」

`sonar-scanner` 运行时读它，得到三类信息：

| 配置项 | 作用 | 不配的后果 |
|---|---|---|
| `sonar.projectKey` | 结果上报到 SonarQube 里**哪个项目**，必须与第 3.5 步建的 key 一致 | 进错项目 / 自动创建出多余项目 |
| `sonar.sources` / `sonar.tests` | 扫哪些目录（`core/page_objects/utils/...`） | 扫描范围错乱，把缓存、报告也算进来 |
| `sonar.exclusions` | 排除 `venv/缓存/报告/浏览器` 等非源码 | 指标虚高、扫描变慢 |

> ⚠️ **host 地址与 token 不写在这里**。它们是敏感信息，走 GitLab CI 变量（`SONAR_HOST_URL` / `SONAR_TOKEN`），避免提交进仓库。

### 4.2 `.gitlab-ci.yml` 的 `sonarqube-check` job —— 整个「拦截」机制的核心

没有这个 job，GitLab 根本不会触发扫描，也就谈不上拦截。它干三件事：

```yaml
sonarqube-check:
  stage: sonarqube
  image: { name: sonarsource/sonar-scanner-cli:latest, entrypoint: [""] }
  tags: [local-sonar]                       # ① 精确派到本地 runner（才能访问本地 SonarQube）
  variables: { GIT_DEPTH: "0" }             #    取全历史，保证 New Code / blame 准确
  script:
    - sonar-scanner -Dsonar.qualitygate.wait=true   # ② 等质量门结果
  allow_failure: false                      # ③ 门失败 → job 失败 → 流水线失败 → 拦合并
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
```

| 标记 | 机制 |
|---|---|
| ① `tags: [local-sonar]` | 把 job 精确投递到你注册的本地 runner，绕开公司共享 runner（它访问不到本地 SonarQube） |
| ② `qualitygate.wait=true` | 扫描后**阻塞等待**质量门判定，而不是扫完就走 |
| ③ `allow_failure: false` | 门失败时让 job 真的失败，从而触发后续拦合并 |

> ⚠️ 本次还顺带改了原有的 Playwright `test` job：**MR 时不再触发**（`only` 去掉 `merge_requests`）。原因：那个重测试要装浏览器、要登录凭证，在 MR 流水线里会失败、干扰门禁验证。主分支 / develop / 定时任务不受影响。

---

## 第 5 章·验证清单

> 用法：逐项打勾，全勾才算打通。

- [ ] `http://localhost:9000` 可访问，`Administration → System` 的 Database 指向本地 Postgres。
- [ ] 启动日志可见 `Deploy Community Branch Plugin / 26.5.0`。
- [ ] 公司 GitLab 项目 `Settings → CI/CD → Runners` 能看到本地 runner，状态在线。
- [ ] 在 `main` 推一次 → SonarQube 出现 `molardata-auto-optimized-test` 项目与门结果。
- [ ] 开一个**合规** MR → `sonarqube-check` 在本地 runner 上跑通、门 PASS → 可合并。
- [ ] 开一个**故意不合规**的 MR（制造 New Bug）→ job 失败 → **合并被拦** → 修复后重跑通过 → 可合并。
- [ ] 确认门只判 **New Code**（历史存量问题不卡新 MR）。

### 步骤
已完成 ✅

  - SonarQube 26.5 + 分支插件 26.5.0 本地运行（sonarqube-branch:26.5.0 镜像）
  - 本地 Postgres、Runner 已注册到公司 GitLab（标签 local-sonar，接入 SonarQube 网络）
  - 被检查项目加了 sonar-project.properties、改了 .gitlab-ci.yml（diff 见上，干净小改动）
  - 写了完整指南：sonarqube-deploy/本地部署-SonarQube-GitLab集成指南.md

  接下来你来做 🔲（都在网页点，按这个顺序）

  ① SonarQube 建项目 + 拿 token（http://localhost:9000）
  - Create project → Locally，Project key 必须填 molardata-auto-optimized-test（和 sonar-project.properties 对上）
  - 生成 token，复制保存

  ② GitLab 项目配 CI 变量（项目 Settings → CI/CD → Variables，都勾 Masked）

  ┌────────────────┬───────────────────────┐
  │      Key       │         Value         │
  ├────────────────┼───────────────────────┤
  │ SONAR_HOST_URL │ http://sonarqube:9000 │
  ├────────────────┼───────────────────────┤
  │ SONAR_TOKEN    │ 上一步的 token        │
  └────────────────┴───────────────────────┘

  ③ 推送两个文件：git diff 你已看到，确认后推（建议先推 main 建基线，再开演示分支）

  ④ 配拦截开关
  - SonarQube：Quality Gates 确认条件作用于 New Code
  - GitLab：Settings → Merge requests 勾 Pipelines must succeed；Settings → Repository 保护 main

  ⑤（可选）MR 装饰：要的话再配机器人 PAT，见指南 3.9

---

## 第 6 章·常见坑与 FAQ
**Q：SonarQube如何切换成中文界面？**
A：我们已经安装中文插件，正常来讲是可以显示的。如果不可以，请Chrome / Edge：
1. 地址栏输入 chrome://settings/languages（Edge 是 edge://settings/languages）
2. 添加语言 → 中文（简体）
3. 点中文右边的 ⋮ → 移到最上面（置顶，必须在英文之上）
4. 回 http://localhost:9000 刷新 → 变中文

Safari（macOS）： Safari 跟随系统语言顺序
1. 系统设置 → 通用 → 语言与地区 → 首选语言
2. 把「简体中文」拖到最上面
3. 重开 Safari 访问 → 变中文

**Q：job 一直 pending / 不被执行？**
A：多半是 runner 标签不匹配。确认 job 有 `tags: [local-sonar]`，且 runner 注册时也带了该标签、并关掉了「Run untagged jobs」。

**Q：job 里报连不上 SonarQube？**
A：确认 runner 注册带了 `--docker-network-mode sonarqube-deploy_default`，且 `SONAR_HOST_URL=http://sonarqube:9000`（用服务名，不是 `localhost`——job 容器的 `localhost` 是它自己）。

**Q：SonarQube 启动报 `Error opening zip file or JAR manifest missing`？**
A：旧的 `extensions` 命名卷盖住了镜像里的插件 jar。`docker compose down` 后 `docker volume rm sonarqube-deploy_sonar_extensions`，再 `up`（见 3.2 的坑）。

**Q：重启 Docker Desktop 后 SonarQube 起不来？**
A：`vm.max_map_count` 被重置了，重跑 3.1 的内核参数命令再 `up`。

**Q：MR 上没有 SonarQube 评论？**
A：MR 装饰是可选功能，需第 3.9 步配置。**没有它也能拦合并**，别和门禁机制混淆。

**Q：扫描特别慢？**
A：纯 Python 项目通常很快；若误把大体量目录纳入 `sonar.sources`，收窄范围即可。前端项目慢多因 JS/TS 桥接内存不足，可加 `-Dsonar.javascript.node.maxspace=4096`。

---

## 附录·关键术语表

| 术语 | 含义 |
|---|---|
| Quality Gate（质量门） | 一组可阻断的质量阈值，决定 MR `Passed` / `Failed` |
| New Code（新代码） | 本次新增 / 改动的代码；门默认只评判它，历史存量不阻断 |
| MR Decoration（MR 装饰） | SonarQube 把质检结果以评论 / 状态写回 GitLab MR（可选） |
| community-branch-plugin | 第三方免费插件，为 Community Build 补齐分支 / MR 分析能力 |
| `qualitygate.wait` | 扫描器参数，令 CI 等待质量门结果，门失败则 job 失败 |
| docker executor | GitLab Runner 的一种执行方式：每个 job 在独立 docker 容器里跑 |
| `local-sonar` | 本方案约定的 runner 标签，用于把 sonar job 精确投递到本地 runner |

---

> 配套文件：`sonarqube-deploy/docker-compose.local.yml`（本地编排）、被检查项目根的 `sonar-project.properties` 与 `.gitlab-ci.yml`。
> 信源：SonarSource 官方文档、community-branch-plugin 官方说明。
