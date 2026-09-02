---
"fnm": minor
---

Automatically clean up multishell directories when the shell session exits

Registers an exit hook/trap in the shell profile evaluation (`fnm env`) that removes the session's multishell symlink directory when the terminal tab or shell session exits.
Supported across Bash (`trap EXIT`), Zsh (`add-zsh-hook zshexit`), Fish (`--on-event fish_exit`), and PowerShell (`Register-EngineEvent PowerShell.Exiting`).
