# SonarQube 自动化代码质量检查平台 · 部署与实施方案

> 一句话定位:在阿里云上以**最小化资源**搭建一套 SonarQube 测试环境,接入团队自建 GitLab,实现"代码 push → MR 自动质检 → 不达标自动拦截合并"的研发质量门禁。
>
> 本文档面向:**DevOps/平台工程师、研发负责人、TPM/项目干系人**。技术执行者读第 2~3 章即可落地;管理干系人读第 1 章与第 3 章路线图即可掌握价值与节奏。

---

## 文档目录

- 第 1 章 [工具概述与价值主张](#第-1-章工具概述与价值主张)
- 第 2 章 [云端架构设计与资源规划](#第-2-章云端架构设计与资源规划)
- 第 3 章 [项目实施路线图与六周迭代规划](#第-3-章项目实施路线图与六周迭代规划)
- 附录 A [配置交付物清单](#附录-a配置交付物清单)
- 附录 B [关键术语表](#附录-b关键术语表)

> ⚙️ 关键技术前置(全文反复引用,先记住):
> - **版本路线**:测试期用 **SonarQube Community Build(免费)+ community-branch-plugin(免费第三方)**。Community Build 官方只能分析主分支一条,该插件补齐**分支分析 + MR 装饰 + 逐 MR 增量门禁**能力。
> - **数据库**:用阿里云**托管 RDS PostgreSQL**,而非容器内自建数据库(纠错点,见 2.3)。
> - **拦截原理**:SonarQube 不直接"卡" GitLab。质检在 GitLab CI 流水线内执行,扫描器以 `sonar.qualitygate.wait=true` 等待质量门结果;门失败 → job 失败 → 流水线失败 → GitLab "Pipelines must succeed" 合并检查 + 受保护分支阻止合并。

---

## 第 1 章·工具概述与价值主张

> 本节小目标:用 5 分钟说清 SonarQube 是什么、能做什么、为什么值得投入。

### 1.1 一句话总结

SonarQube 是一个**静态代码质量与安全分析平台**:它在代码合入主干前自动"体检",把 Bug、漏洞、坏味道、重复代码、覆盖率不足等问题在 Merge Request 阶段暴露出来,并可作为**强制门禁**阻止不达标代码合并。

类比:SonarQube 之于代码,相当于**机场安检之于行李** —— 每个 MR 都要过一次安检门,违禁品(质量缺陷)不清掉就不让登机(合并)。

### 1.2 核心功能

| 功能 | 解决什么问题 | 典型产出 |
|---|---|---|
| **静态代码分析(SAST)** | 不运行程序即可发现 Bug 与逻辑缺陷 | 问题列表,按严重级别(Blocker→Info)分级 |
| **安全漏洞检测** | 识别注入、硬编码密钥、危险 API 等安全风险 | Vulnerabilities + Security Hotspots |
| **代码坏味道(Code Smell)** | 度量可维护性,量化技术债务 | 技术债工时(如"修复需 3d 2h") |
| **代码重复率(Duplication)** | 发现复制粘贴式编码 | 重复行数/重复块占比 |
| **测试覆盖率(Coverage)** | 衡量测试充分度(需 CI 上传覆盖率报告) | 行覆盖率/条件覆盖率百分比 |
| **质量门(Quality Gate)** | 把"好/坏"标准固化为可阻断的规则 | `Passed` / `Failed` 状态 |
| **多分支与 MR 装饰** | 只评判**本次改动(New Code)**,并把结果写回 MR | MR 内联评论 + 通过状态 |

> ⚠️ 关键认知:质量门默认作用于 **New Code(本次新增/改动的代码)**,而非历史存量。这保证"新债不增量",团队不会被历史遗留问题一次性卡死,落地阻力最小。

### 1.3 研发侧价值主张

- **提升代码质量,左移缺陷**:问题在合并前暴露,修复成本远低于上线后。行业经验:缺陷发现越晚,修复成本呈指数级上升。
- **量化并遏制技术债务**:技术债从"凭感觉"变成"可度量的工时数字",为重构与排期提供客观依据。
- **保障线上稳定性**:漏洞与高危 Bug 在门禁处被拦截,降低生产事故与安全事件概率。
- **统一团队标准,沉淀规范**:质量门是"全队共识的代码底线",新人也能被同一把尺子约束,减少 Code Review 中的主观争论。
- **自动化、零打扰**:质检嵌入 CI 流水线自动触发,开发者无需手工操作,结果直接呈现在 MR 上。

---

## 第 2 章·云端架构设计与资源规划

> 本节小目标:给出测试环境的整体架构图、最小化资源清单与选型理由,确保"资源最少、成本最低、能跑通全链路"。

### 2.1 整体架构(测试环境)

```
                        研发同学 push / 开 MR
                                  │
                                  ▼
                 ┌────────────────────────────────┐
                 │   自建 GitLab(已有,官网域名)   │
                 │   - 触发 MR 流水线               │
                 │   - 合并检查 / 受保护分支拦截     │
                 └───────┬───────────────▲─────────┘
            ① 流水线运行   │               │ ④ 写回 MR 装饰/质量门状态
            sonar-scanner │               │   (SonarQube → GitLab API)
                          ▼               │
                 ┌──────────────────┐     │
                 │  GitLab Runner   │─────┘
                 │ (执行扫描 job)    │
                 └───────┬──────────┘
            ② 上报结果 +   │ 轮询质量门(qualitygate.wait)
               拉取门状态  ▼
        ┌─────────────────────────────────────────────┐
        │           阿里云 VPC(同一专有网络)            │
        │                                             │
        │   ┌───────────────────────┐                 │
        │   │  ECS(4C16G)           │   ③ 内网 5432   │
        │   │  Docker:               │ ───────────────►│
        │   │   - SonarQube CE       │   ┌───────────┐ │
        │   │   - branch-plugin      │   │ RDS       │ │
        │   │   - (Nginx 反代 HTTPS) │   │ PostgreSQL│ │
        │   └───────────────────────┘   └───────────┘ │
        │     ▲ EIP(按来源 IP 白名单)                  │
        └─────┼───────────────────────────────────────┘
              │ 管理员访问 Web(9000/443)
```

数据流四步:① Runner 在 MR 流水线里跑 `sonar-scanner` → ② 结果上报 SonarQube 并轮询质量门 → ③ SonarQube 读写 RDS 元数据 → ④ SonarQube 调 GitLab API 把结论写回 MR。

### 2.2 标准云资源清单(最小化)

| # | 云资源 | 用途 | 选型理由(测试期最小化) | 建议规格 |
|---|---|---|---|---|
| 1 | **ECS** ×1 | 运行 Docker 版 SonarQube(内嵌 Elasticsearch) | 单机足够;内嵌 ES 对内存敏感,故 16 GB 起 | 通用型 `g` 系列 **4 vCPU / 16 GB**,系统盘 + ESSD 数据盘 ≥ 100 GB,Alibaba Cloud Linux 3 |
| 2 | **RDS PostgreSQL** ×1 | SonarQube 元数据库(项目、问题、历史) | **托管库替代容器自建库**:免运维、自动备份、数据与计算解耦(纠错重点,见 2.3) | 基础版 **2 vCPU / 4 GB**,PostgreSQL **14/15/16**,存储 ≥ 20 GB |
| 3 | **VPC + 交换机** | 网络隔离,ECS 与 RDS 内网互通 | 同 VPC 同可用区,RDS 走**内网地址**,低延迟、不走公网 | 1 个 VPC + 1 个交换机 |
| 4 | **安全组** | 入站/出站访问控制 | 最小放行:按来源 IP 白名单 | 见 2.4 |
| 5 | **EIP / 公网 IP**(绑 ECS) | 让 GitLab Runner 访问 SonarQube、SonarQube 回调 GitLab API | 测试期最简连通方式,配合安全组收紧 | 1 个 EIP,按固定带宽或按量 |
| 6 | **RAM 子账号** | 运维人员最小权限访问控制台 | 免费,满足权限合规 | 1~2 个子账号 |

**测试期明确不引入**(降本)的资源,以及"为什么现在不需要":

| 资源 | 生产期作用 | 测试期为何省略 |
|---|---|---|
| **SLB / ALB** | HTTPS 接入 + 高可用 | 单机测试用 ECS 内 Nginx/Caddy 反代即可 |
| **OSS** | 备份归档 | 测试数据可弃,用 RDS 自动备份 + 磁盘快照兜底 |
| **ACK(K8s)** | 弹性编排 | 单实例 SonarQube 上 K8s 是过度设计,徒增复杂度与成本 |
| **多可用区 / RDS 高可用版** | 容灾 | 测试环境不需要,生产期再升级 |

### 2.3 ⚠️ 架构纠错:为什么用托管 RDS,而非容器内自建数据库

部分初版方案会把 PostgreSQL 也塞进 `docker-compose` 与 SonarQube 同机运行。**测试可以,生产强烈不建议**,本方案从测试期就采用托管 RDS,理由如下:

- **数据持久性与解耦**:容器是"易失"的,把有状态数据库与无状态应用绑在同一生命周期,一次误删容器/卷即丢全部历史数据。
- **免运维备份与恢复**:RDS 提供自动备份、时间点恢复;自建需自己写备份脚本、自己验证可恢复性。
- **资源争抢**:SonarQube 的内嵌 Elasticsearch 本身吃内存,数据库与其抢同机资源会相互拖累稳定性。
- **平滑升生产**:测试期就用 RDS,后续升生产只需把 RDS 换成高可用版,架构零改动。

> 结论:**有状态用托管服务,无状态用容器** —— 这是云原生的基本分工。

### 2.4 网络与安全组(连通性是最易踩的坑)

链路要求**双向连通**,缺一不可:

| 方向 | 端口/协议 | 用途 | 安全组策略 |
|---|---|---|---|
| GitLab Runner → SonarQube | `9000`(或反代 `443`) | 上报扫描结果、轮询质量门 | 入站仅放行 Runner 出口 IP |
| SonarQube → GitLab API | `443` 出站 | MR 装饰、写回门状态 | 出站放行到 GitLab 域名 |
| ECS → RDS | `5432` 内网 | 读写元数据 | 把 ECS 内网 IP/安全组加入 RDS **白名单** |
| 管理员 → SonarQube Web | `9000` / `443` | 控制台管理 | 入站仅放行运维公网 IP |

> ⚠️ 安全红线:`9000`、`22(SSH)` 等入站**一律按来源 IP 白名单**,严禁对 `0.0.0.0/0` 开放。

---

## 第 3 章·项目实施路线图与六周迭代规划

> 本节小目标:把项目拆成 6 周敏捷迭代,每周写清**目标 / 任务拆解 / 验收标准 / 产出物 / 风险提示**,做到可排期、可验收。

### 3.1 角色与假设

| 角色 | 职责 | 人力 |
|---|---|---|
| TPM / 项目负责人 | 排期、干系人对齐、验收 | 0.2 人 |
| DevOps 架构师(主力) | 架构、部署、CI 集成、调优 | 1 人 |
| GitLab 管理员 | 账号/PAT、Runner、合并检查配置 | 0.2 人 |
| 试点研发团队 | 提供试点项目、试用反馈 | Week 4 起介入 |

> 假设:团队规模小(< 50 项目),GitLab 已就绪,阿里云账号与预算已批。周期按 **6 周** 推演,可据复杂度伸缩到 4~6 周。

### 3.2 对前期调研笔记的纠错与补充

> 本路线图以前期 6 周调研笔记为骨架,保留其合理的迭代节奏与"目标/任务/验收/产出/风险"模板;以下为按行业最佳实践的**关键纠正与增强**,正文各周已据此落实。

| # | 原笔记观点 | 问题 / 风险 | 本方案修正 |
|---|---|---|---|
| 1 | 内存建议 2 GB 以上 | 偏低:内嵌 Elasticsearch,2 GB 必然频繁 OOM、启动不稳 | 主机内存 ≥ **4 GB**,测试期定 **4 vCPU / 16 GB** |
| 2 | 按需配置 PostgreSQL(暗示容器内自建) | 有状态数据与容器同生命周期,易丢数据、难备份 | 用**托管 RDS PostgreSQL**(见 2.3) |
| 3 | (未提及内核参数) | 漏配 `vm.max_map_count` 是 SonarQube 启动失败的头号原因 | Week 1 必做 `vm.max_map_count=524288` |
| 4 | GitLab CI 或 Jenkins(二选一含糊) | 已确定自建 GitLab,Jenkins 是多余组件 | 统一用 **GitLab CI**,不引入 Jenkins |
| 5 | 配置 PR 状态反馈(通过/失败) | **Community Build 原生不支持** MR 装饰与分支分析 | 必须安装 **community-branch-plugin** 才能实现(笔记遗漏的关键前提) |
| 6 | Quality Gate:Bug=0 / Critical=0 / Coverage≥70% | 若作用于**整体代码**,存量项目会被一次性卡死、引发抵触 | 阈值作用于 **New Code**,存量不阻断 |
| 7 | 在 CI 中"加入 gate check"(机制含糊) | 不清楚靠什么真正拦住 merge | 明确机制:`-Dsonar.qualitygate.wait=true` + GitLab Merge checks "Pipelines must succeed" + 受保护分支 |
| 8 | Week 5 接 OWASP Dependency-Check + Semgrep | 与 Sonar 能力部分重叠,对"测试环境"有范围蔓延风险 | 列为**进阶可选**,并厘清分工:Sonar=SAST/Hotspot,OWASP DC=依赖 CVE(SCA),Semgrep=自定义规则;异步执行不阻塞主流程 |

### 3.3 六周路线图总览(甘特概览)

```
周次       W1        W2        W3        W4        W5        W6
          ───────── ───────── ───────── ───────── ───────── ─────────
W1 环境+Demo █████████
W2 CI 接入            █████████
W3 质量门禁                     █████████
W4 覆盖率+稳定                            █████████
W5 安全增强(可选)                                  █████████
W6 优化+推广                                                  █████████
          ─────────────────────────────────────────────────────────►
里程碑     M1 跑通    M2 自动扫  M3 拦截    M4 指标可信 (M5 安全)  M6 推广
```

| 里程碑 | 完成标志 | 时点 |
|---|---|---|
| M1 最小可运行 | Web UI 可访问,Demo 项目出 Bug/Code Smell,DB 指向 RDS | W1 末 |
| M2 自动扫描 | push/开 MR 自动触发流水线扫描,结果自动更新 | W2 末 |
| M3 门禁拦截 | 不合格 MR 被自动拦截、合格可合并,MR 上有装饰 | W3 末 |
| M4 指标可信 | 覆盖率正确显示,报告稳定、误报可控 | W4 末 |
| M5 安全增强(可选) | 能识别依赖 CVE,高危可触发阻断 | W5 末 |
| M6 全员推广 | ≥2 项目接入,团队主动使用,CI 稳定 | W6 末 |

> 说明:笔记把"开通云资源"隐含在 Week 1。本方案显式把 **VPC/ECS/RDS/安全组开通 + 内核参数** 作为 Week 1 的前置任务,避免测试期最常见的"环境没就绪就开始装"的返工。

### 3.4 六周迭代详规

> 每周统一用「目标 / 任务拆解 / 验收标准 / 产出物 / 风险提示」五字段组织(沿用笔记模板);🔧 标记处为对原笔记的纠错或补充。

#### Week 1 · 环境搭建 + 最小可运行 Demo

- **目标**:SonarQube 在阿里云跑起来,跑通第一个项目扫描。
- **任务拆解**:
  - 🔧 (前置)开通 VPC/ECS(`4C16G`)/RDS PostgreSQL,配安全组与 RDS 白名单。
  - 🔧 主机执行 `host-setup.sh` 设置 `vm.max_map_count=524288` 等内核参数。
  - 🔧 用 `docker compose` 启动 SonarQube + `community-branch-plugin`,`SONAR_JDBC_URL` 指向 **RDS**(而非容器自建库)。
  - 登录后台改密、生成 Analysis Token、创建第一个 Project。
  - 选一个小服务作为 demo,本地或 CI 跑通 `sonar-scanner`。
- **验收标准**:Web UI 可正常访问;能看到 Bug / Code Smell 结果;`Administration → System` 显示 DB 指向 RDS;日志显示分支插件已加载。
- **产出物**:运行截图、第一份扫描报告、1 页接入说明。
- **风险提示**:
  - 🔧 内存 ≥ **4 GB**(笔记的 2 GB 会反复启动失败),测试期用 16 GB。
  - 🔧 漏配 `vm.max_map_count` → 内嵌 Elasticsearch 启动失败(头号坑)。
  - `sonar-scanner` 与 SonarQube 版本要匹配;**插件版本须与 SonarQube 主.次版本一致**。

#### Week 2 · CI 接入(关键周)

- **目标**:push 代码 / 开 MR → 自动触发扫描。
- **任务拆解**:
  - 🔧 统一用 **GitLab CI**(不引入 Jenkins):在被检查项目加 `.gitlab-ci.yml`,用 `sonarsource/sonar-scanner-cli` 镜像,`rules` 命中 MR 事件与默认分支。
  - 配 CI 变量 `SONAR_HOST_URL` / `SONAR_TOKEN`(Masked/Protected)。
  - 确认有可达 SonarQube 的 **GitLab Runner**。
  - 调通 coverage 输出(本周不要求完美)。
- **验收标准**:push/MR 自动触发,pipeline 无报错;SonarQube 分析结果自动更新。
- **产出物**:`.gitlab-ci.yml`、CI 运行截图、pipeline 流程说明。
- **风险提示(本周最易卡)**:
  - Runner 网络访问不到 SonarQube(需双向连通,见 2.4)。
  - coverage 路径配置错误。
  - token 权限不足。

#### Week 3 · 质量门禁(Quality Gate)

- **目标**:代码不达标 → 阻断合并。
- **任务拆解**:
  - 🔧 配置 Quality Gate,条件**作用于 New Code**:`New Bugs = 0`、`New Blocker/Critical = 0`、`New Code Coverage ≥ 70%`、重复率阈值。
  - CI 中加 `-Dsonar.qualitygate.wait=true` 且 `allow_failure: false`。
  - GitLab 开启 Merge checks **"Pipelines must succeed"** + 保护主分支(禁止直推)。
  - 🔧 借助 `community-branch-plugin` 实现 **MR 装饰**(通过/失败写回 MR)。
- **验收标准**:MR 上能看到质量状态与装饰评论;不合格代码无法 merge;合格可 merge。
- **产出物**:Quality Gate 配置截图、CI 阻断示例、门禁规则说明文档。
- **风险提示**:
  - 🔧 阈值务必套 **New Code**,不要套整体(否则存量项目全红、团队抵触)。
  - 🔧 "PR 状态反馈"依赖分支插件 —— Community Build 原生没有(笔记遗漏)。
  - 初期不要把规则定得过严。

#### Week 4 · 覆盖率接入 + 稳定性优化

- **目标**:指标可信,报告稳定。
- **任务拆解**:
  - CI 测试步骤生成覆盖率报告(`pytest-cov → coverage.xml` / JaCoCo → xml),用 `sonar.<lang>.coverage.reportPaths` 上传。
  - 修复 coverage 不显示问题(多为路径/格式错误)。
  - 关停明显误报规则,优化 Quality Profile。
- **验收标准**:coverage 数据正确显示;报告稳定,无明显误报干扰。
- **产出物**:coverage 报告截图、覆盖率说明文档、问题修复记录。
- **风险提示**:
  - coverage XML 路径配置错误(高频问题,优先排查;路径相对仓库根)。
  - 🔧 补充:SonarQube **不运行测试**,覆盖率由 CI 生成后上传,二者职责分离。

#### Week 5 · 安全扫描 + 规则增强(进阶可选)

- **目标**:在代码质量基础上叠加安全检测。
- **任务拆解**:
  - 先用好 SonarQube 自带的 **Vulnerabilities / Security Hotspots**(无需额外组件)。
  - (可选)接入 **OWASP Dependency-Check** 输出依赖 CVE(SCA 层)。
  - (可选)引入 **Semgrep** 补充自定义规则。
  - 高危漏洞可触发 CI 阻断;安全扫描放独立 stage、异步执行。
- **验收标准**:能识别依赖漏洞;高危漏洞可触发 CI 阻断。
- **产出物**:安全扫描报告、CVE 清单、CI 安全检查流程说明。
- **风险提示**:
  - 安全扫描耗时较长 → 异步执行、与主流程解耦。
  - 🔧 厘清分工避免重复:Sonar = SAST/Hotspot,OWASP DC = 依赖 CVE,Semgrep = 自定义 SAST。
  - 🔧 测试阶段警惕范围蔓延,本周可整体下沉为后续迭代,不阻塞核心门禁上线。

#### Week 6 · 优化 + 推广 + 总结

- **目标**:系统被团队接受,稳定持续运行。
- **任务拆解**:
  - 调整规则降低误报率,门禁阈值调至合理水平。
  - 接入第 2 个项目,沉淀 `.gitlab-ci.yml` 标准模板。
  - 整理完整文档,做团队宣讲;🔧 输出生产化评估。
- **验收标准**:至少 2 个项目完成接入;开发团队愿意主动使用;CI 稳定运行,无持续报错。
- **产出物**:《代码质量体系说明文档》、项目接入指南、质量分析报告(汇报版)、🔧《生产化建议书》(Developer Edition 去插件依赖 / RDS 高可用 / 前置 ALB / 备份与监控)。

### 3.5 风险与应对(总表)

| 风险 | 影响 | 应对 |
|---|---|---|
| 插件与 SonarQube 版本不匹配 | 平台无法启动 / 无 MR 装饰 | Week 1 前严格核对配对版本并钉死,升级前在测试环境先验证 |
| 内存不足(沿用 2 GB) | 服务频繁 OOM、启动不稳 | 主机 ≥ 4 GB,测试期 16 GB |
| 网络双向不通 | 扫描无法上报 / 无法装饰 MR | Week 1~2 按 2.4 表打通并做连通性测试 |
| 质量门过严 | 团队抵触、阻塞交付 | 门只判 New Code;Week 4 用真实数据调阈值 |
| 安全扫描范围蔓延 | 拖慢主流程、延期 | Week 5 列为可选、异步解耦,必要时下沉到后续迭代 |
| 第三方插件停更 | 长期维护风险 | 生产期评估迁移官方 Developer Edition |

---

### 3.6 Week 1–6 验收 Checklist

> 用法:每周收尾时逐项打勾,**全勾才算该周达成**。勾不满的项进入下周作为遗留事项。

**Week 1 · 环境 + Demo**
- [ ] VPC / ECS(`4C16G`)/ RDS PostgreSQL 已开通,ECS 与 RDS 同 VPC、内网可达
- [ ] 安全组与 RDS 白名单按 2.4 配好(入站按来源 IP 白名单)
- [ ] 主机 `vm.max_map_count` 已为 `524288`(`sysctl vm.max_map_count` 核验)
- [ ] `docker compose up -d` 后日志出现 `SonarQube is operational`
- [ ] 启动日志可见 `community-branch-plugin` 已加载
- [ ] `Administration → System` 显示数据库指向 **RDS**(非本地容器)
- [ ] Web UI 可访问,Demo 项目能看到 Bug / Code Smell
- [ ] 产出:运行截图、首份扫描报告、1 页接入说明

**Week 2 · CI 接入**
- [ ] 被检查项目已加 `.gitlab-ci.yml`(`sonar-scanner-cli` 镜像)
- [ ] CI 变量 `SONAR_HOST_URL` / `SONAR_TOKEN` 已配且 Masked/Protected
- [ ] 存在可访问 SonarQube 的 GitLab Runner(连通性已实测)
- [ ] push / 开 MR 能自动触发 pipeline,且无报错
- [ ] SonarQube 中该项目分析结果随提交自动更新
- [ ] 产出:`.gitlab-ci.yml`、CI 运行截图、pipeline 流程说明

**Week 3 · 质量门禁**
- [ ] Quality Gate 条件**全部作用于 New Code**(New Bugs=0、New Blocker/Critical=0、New Coverage≥70%)
- [ ] CI 已加 `-Dsonar.qualitygate.wait=true` 且 `allow_failure: false`
- [ ] GitLab 已开 Merge checks **"Pipelines must succeed"**,主分支已保护、禁止直推
- [ ] 合规改动 MR → 门 PASS、收到 MR 装饰评论 → **可合并**
- [ ] 不合规改动 MR → 门 FAIL、流水线失败 → **合并被拦**
- [ ] 确认历史存量问题不阻断新 MR(仅判 New Code)
- [ ] 产出:Quality Gate 截图、CI 阻断示例、门禁规则说明

**Week 4 · 覆盖率 + 稳定性**
- [ ] CI 测试步骤生成覆盖率报告,并经 `sonar.<lang>.coverage.reportPaths` 上传
- [ ] SonarQube 中 coverage 数值正确显示(非 0、非空)
- [ ] 已关停明显误报规则,报告稳定
- [ ] 产出:coverage 截图、覆盖率说明、问题修复记录

**Week 5 · 安全增强(可选)**
- [ ] SonarQube 自带 Vulnerabilities / Security Hotspots 已在用
- [ ] (可选)OWASP Dependency-Check 能输出依赖 CVE
- [ ] (可选)Semgrep 自定义规则已接入
- [ ] 高危漏洞可触发 CI 阻断;安全扫描为独立 stage、异步执行
- [ ] 产出:安全扫描报告、CVE 清单、安全检查流程说明

**Week 6 · 优化 + 推广**
- [ ] 误报率已降至可接受,门禁阈值调至合理水平
- [ ] **≥ 2 个项目**完成接入,沉淀出 `.gitlab-ci.yml` 标准模板
- [ ] 完成团队宣讲与培训,开发团队愿意主动使用
- [ ] CI 连续运行稳定、无持续报错
- [ ] 产出:《代码质量体系说明文档》、接入指南、汇报版质量报告、《生产化建议书》

---

## 附录 A·配置交付物清单

本方案配套的可直接落地的配置文件已生成于代码库 `sonarqube-deploy/` 目录:

| 文件 | 部署位置 | 作用 |
|---|---|---|
| `.env.example` | ECS | 复制为 `.env`,钉死版本、填 RDS 连接 |
| `docker-compose.yml` | ECS | 启动 SonarQube + 自动装载分支插件 + 连 RDS |
| `host-setup.sh` | ECS | 设置内核参数(`vm.max_map_count` 等) |
| `project-template/.gitlab-ci.yml` | 被检查项目仓库根 | MR 触发质检,门失败即拦 |
| `project-template/sonar-project.properties` | 被检查项目仓库根 | projectKey、源码范围、覆盖率报告路径 |

## 附录 B·关键术语表

| 术语 | 含义 |
|---|---|
| Quality Gate(质量门) | 一组可阻断的质量阈值,决定 MR `Passed`/`Failed` |
| New Code(新代码) | 本次新增/改动的代码;门默认只评判它 |
| MR Decoration(MR 装饰) | SonarQube 把质检结果以评论/状态写回 GitLab MR |
| Code Smell(坏味道) | 不影响功能但损害可维护性的代码,折算为技术债工时 |
| Security Hotspot | 需人工研判的安全敏感点(未必是漏洞) |
| community-branch-plugin | 第三方免费插件,为 Community Build 补齐分支/MR 分析能力 |
| `qualitygate.wait` | 扫描器参数,令 CI 等待质量门结果,门失败则 job 失败 |

---

> 信源说明: 架构与流程依据 SonarSource 官方文档、`community-branch-plugin` 官方说明及阿里云产品文档(托管数据库、最小化资源、流水线门禁)。
