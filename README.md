# µOS++ III SMP in Zig (`micro-os-plus-iii-smp-zig`)

The repositories of the workspace `micro-os-plu-iii-smp-zig-pr-github` in one repository. Each was a
separate git repository; here each is merged, with its full history, in the folder
it had in the workspace (`git subtree add`, commits not rewritten).

| Folder | Branch | Commit | Its own remote before |
| --- | --- | --- | --- |
| `micro-os-plus-iii/` | `smp` | `6e5166c` | `~/Downloads/GIT/micro-os-plus-iii-zig.git` |
| `micro-os-plus-iii-aarch32/` | `smp` | `d89ac99` | `~/Downloads/GIT/micro-os-plus-iii-aarch32-zig.git` |
| `micro-os-plus-iii-aarch64/` | `smp` | `66268f5` | `~/Downloads/GIT/micro-os-plus-iii-aarch64-zig.git` |
| `micro-os-plus-iii-cortexm/` | `smp` | `826afbb` | `~/Downloads/GIT/micro-os-plus-iii-cortexm-zig.git` |
| `micro-os-plus-iii-posix-arch/` | `smp` | `5cdd9ef` | `~/Downloads/GIT/micro-os-plus-iii-posix-arch-zig.git` |

One `git clone` gets everything; `git log -- <folder>` shows the history of one part.
