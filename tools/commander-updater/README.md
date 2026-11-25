# Windows Commander release workflow

This PC runs `Update-Forge.ps1` from `%LOCALAPPDATA%\Card-Forge` in the existing daily Windows task. Official archives are staged and checked against GitHub's size and SHA-256 before building. `Prepare-ForgeRelease.ps1` creates a clean worktree at that release's official tag, cherry-picks `6c82f1a1dd4eaa579782cc53b9086ef8288fc33e`, compiles the changed production Java classes against that release's official desktop JAR, and packages those classes into a separate release copy.

The test run compiles CommanderAttackTests, BasicAttackTests, BasicBlockTests, FlatMonteCarloAttackTest, and PlayerMustAttackTest from the port worktree. Its runtime classpath contains the candidate packaged JAR, test classes, and pinned TestNG dependencies. Compiled production class directories are excluded. The tests use an isolated profile. The six Commander regressions and all existing tests in those attack, blocking, and forced-attack classes must pass without skips. A hash-bound approval and test report travel with the package.

Only approved Commander build IDs can be activated. The updater, builder, and rollback command share an exclusive file lock. `current.txt` and `previous.txt` are atomically replaced. Build directories are immutable after activation. The launcher checks the package and test evidence, and can recover using the previous approved copy. Existing game processes continue in their original folders.

## Port failures

Read `commander-status.json` and `updates.log` in the installation folder. The status identifies the release, source worktree, source commit, build logs, and failure. Resolve the port in the named worktree, preserve all six Commander regressions, and commit the adapted source. Run the installed script with `-Tag forge-VERSION -ResumePort` to rebuild and retest before activation. Use `-Retry` after repairing a transient failure without changing the source commit. An unchanged failing source is retained for attention instead of repeatedly creating packages. Push adapted release branches to Cowbacca/forge for review.

The Codex check in the existing chat handles ports that need adaptation and reports failures or activations. It requires the app to be running to perform source adaptations. The Windows task handles ports that apply and pass automatically.

## Rollback

Run the installed `Rollback-Forge.ps1` to select the previous approved build. Both copies remain on disk. The desktop and taskbar shortcuts continue using the installed launcher.

## Verification and installation

Bootstrap an isolated directory with the official verified 2.0.16 archive, the configuration, dependencies, and the regression-tested existing Commander build. Run `Prepare-ForgeRelease.ps1` against it, then `Test-ForgeWorkflow.ps1`. The latter checks activation rejection, package tampering, exclusive locking, rollback, launcher recovery, an unfinished port, a real packaged regression failure, and successful retry. It deliberately breaks and restores the isolated port source. `Install-ForgeWorkflow.ps1` requires that evidence before replacing the scheduled workflow and preserves the previous scripts and task definition.
