# jobmon

超算作业跑完了，手机响一下。

一个 macOS 上的极轻量 Slurm 作业完成提醒器：你在集群上提交作业，`jobmon on` 唤醒监测，作业结束时通过钉钉群机器人推送 ✅ 成功 / ❌ 失败（带 ExitCode、用时、结束时间），然后**它把自己从 launchd 卸载干净**，空闲期零后台活动。

## 为什么是这个样子

最初的需求很明确：不要常驻服务、不要占用资源、也不要让 AI 一直盯着看。所以三条设计原则：

- **没有守护进程。** 每次运行是 `launchd` 拉起的一个短命脚本，查一轮状态、发一条通知、退出，存活 1–2 秒。
- **按需唤醒，用完自停。** 只有 `jobmon on` 之后才存在定时任务；最后一个作业通知完，下一轮在发起任何 SSH 之前就把自己卸载掉。
- **不碰网页控制台。** 与其反向工程作业管理页面、还要处理 Cookie 过期，不如直接 `ssh <集群> sacct -j <id>`——一次查询同时拿到「跑完没有」和「成功还是失败」。

## 前置条件

- macOS（依赖 `launchd` 与 `osascript`）
- 一个能免密登录的 Slurm 集群入口，写在 `~/.ssh/config` 里，例如：

  ```
  Host mycluster
      HostName login.example.edu
      User alice
      IdentityFile ~/.ssh/id_ed25519
      IdentitiesOnly yes
      UseKeychain yes        # 密钥带口令时，让 launchd 环境也能读到
  ```

  > `UseKeychain yes` 很关键：launchd 拉起的进程没有 `SSH_AUTH_SOCK`，靠它才能从钥匙串取口令。
- 一个钉钉群 + 群内「自定义机器人」（群设置 → 智能群助手 → 添加机器人 → 自定义，安全设置选「加签」）

## 安装

```bash
git clone https://github.com/xxoliverxx/jobmon.git && cd jobmon
./install.sh
```

然后编辑 `~/.config/jobmon/config.sh`，填 `SSH_HOST`、`CLUSTER_USER` 和钉钉 webhook / 密钥，最后验证：

```bash
jobmon test      # 手机收到消息即配置正确
```

## 使用

```bash
ssh mycluster sbatch job.sh   # 照常提交
jobmon on                     # 唤醒监测：登记队列里你所有在跑/排队的作业
```

| 命令 | 作用 |
| --- | --- |
| `jobmon on` | 唤醒监测，自动登记当前队列中你的全部作业 |
| `jobmon on <id>...` | 唤醒并额外登记指定作业 ID |
| `jobmon` | 查看状态：监测器是否唤醒、监测中的作业、队列概览 |
| `jobmon off` | 立即停止并清空列表 |
| `jobmon forget <id>` | 从列表移除某个作业 |
| `jobmon test` | 发一条钉钉测试消息 |
| `jobmon reset` | 清除「已通知」标记，让作业可重新通知 |

唤醒期间新提交的作业也会被自动登记，不必逐条 `watch`。全部跑完就自动休眠，不需要手动关。

## 工作原理

```
jobmon on ──► launchctl bootstrap（StartInterval 180s + RunAtLoad）
                    │
                    ▼
              jobmon poll ──► watchlist 为空？──是──► launchctl bootout（自我卸载）
                    │
                   否
                    ▼
        squeue -u <user>  自动发现新作业并入列
                    ▼
        sacct -j <id> -X  读 State / ExitCode
                    ▼
        仍在运行 → 什么都不做，等下一轮
        进入终态 → 记入本轮 session → 逐条通知（可关）→ 移出列表
                    ▼
        列表清空 → 发一条「本轮全部结束」汇总 → 下一轮开头自我卸载
```

**成功判定是 `State=COMPLETED` 且 `ExitCode=0:0`，两者缺一不可。** 只看 `ExitCode` 会把被取消的作业当成成功——`CANCELLED by <uid>` 的退出码同样可能是 `0:0`；只看 `State` 又会漏掉「跑完了但算错了」的作业。

## 通知策略

| 配置项 | 默认 | 作用 |
| --- | --- | --- |
| `NOTIFY_EACH` | `1` | `0` = 不逐条推送，只在本轮全部结束后发一条汇总 |
| `SUMMARY_MIN_JOBS` | `2` | 本轮作业数达到该值才追加汇总；单个作业不多打扰一次 |
| `POLL_DESKTOP` | `1` | 是否同时弹 macOS 桌面通知 |

一次提交十几个作业时，把 `NOTIFY_EACH` 设为 `0`：整批只收一条消息。汇总按**作业名分组**给出数量，并单独列出需要关注的作业号与状态：

```
🏁 本轮 5 个作业已结束（成功 3 / 异常 2）
- demoA_fit × 3（异常 1）
- demoB_stage × 2（异常 1）

需要关注的作业
- 91003 demoA_fit (FAILED / 1:0)
- 91005 demoB_stage (CANCELLED by 123 / 0:0)
```

`NOTIFY_EACH=0` 时汇总必定发送，不受 `SUMMARY_MIN_JOBS` 限制。

## 几个刻意的设计

- **SSH 不通 ≠ 作业结束。** `sacct` 返回空或连不上集群时只记日志跳过，绝不发「已完成」的假通知。断网、合盖、VPN 掉线都不会误报。
- **通知只发一次。** 用 `~/.local/state/jobmon/<id>.notified` 标记去重，否则每 3 分钟就会轰炸一次。命中该标记时顺手把 ID 移出列表，保证监测器能判定「自己该睡了」。
- **汇总等的是队列真空。** 每轮都会用 `squeue` 重新发现作业并入列，所以「本轮全部结束」指的是你名下确实不再有作业在跑，而不是「我登记的那几个跑完了」——中途补交的作业不会漏。
- **没有可监测作业时拒绝唤醒。** 否则「先 on 后提交」会让监测器在下一轮立刻判定空闲并休眠，反而漏掉作业。
- **自我卸载不能用派生子进程。** 曾试过 `nohup sh -c 'sleep 2; launchctl bootout ...' &`，但 launchd 会在作业主进程退出时回收它派生的所有子进程，卸载请求根本发不出去。正确做法是在下一轮 poll 的开头、任何 SSH 之前直接 `bootout` 自身。

## 已知限制

- 合盖睡眠期间 launchd 不运行，唤醒后下一轮补上通知（不会丢，只是延迟）。
- 集群地址若是内网 IP，Mac 必须在 VPN / 校园网内。
- 监测器已加载时若重启，登录会恢复该 LaunchAgent 并继续监测列表中的作业；若重启发生在休眠期，则需重新 `jobmon on`。
- 钉钉自定义机器人限频 20 条/分钟，且**只能推送、无法接收**——在群里 @ 机器人不会有任何反应。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `~/bin/jobmon` | 主脚本 |
| `~/.config/jobmon/config.sh` | 配置（权限 600，含 webhook 密钥，勿提交） |
| `~/Library/LaunchAgents/cn.ojlab.jobmon.plist` | 定时任务定义，按需加载/卸载 |
| `~/.local/state/jobmon/` | watchlist、`<id>.notified` 标记、`jobmon.log` |

卸载：

```bash
launchctl bootout gui/$(id -u)/cn.ojlab.jobmon
rm -f ~/bin/jobmon ~/Library/LaunchAgents/cn.ojlab.jobmon.plist
rm -rf ~/.config/jobmon ~/.local/state/jobmon
```

## License

MIT
