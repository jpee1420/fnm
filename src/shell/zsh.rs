use crate::version_file_strategy::VersionFileStrategy;

use super::shell::Shell;
use indoc::formatdoc;
use std::path::Path;

#[derive(Debug)]
pub struct Zsh;

impl Shell for Zsh {
    fn to_clap_shell(&self) -> clap_complete::Shell {
        clap_complete::Shell::Zsh
    }

    fn path(&self, path: &Path) -> anyhow::Result<String> {
        let path = path
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("Path is not valid UTF-8"))?;
        let path =
            super::windows_compat::maybe_fix_windows_path(path).unwrap_or_else(|| path.to_string());
        Ok(format!("export PATH={path:?}:$PATH"))
    }

    fn set_env_var(&self, name: &str, value: &str) -> String {
        format!("export {name}={value:?}")
    }

    fn rehash(&self) -> Option<&'static str> {
        Some("rehash")
    }

    fn use_on_cd(&self, config: &crate::config::FnmConfig) -> anyhow::Result<String> {
        let version_file_exists_condition = if config.resolve_engines() {
            "-f .node-version || -f .nvmrc || -f package.json"
        } else {
            "-f .node-version || -f .nvmrc"
        };
        let autoload_hook = match config.version_file_strategy() {
            VersionFileStrategy::Local => formatdoc!(
                r"
                    if [[ {version_file_exists_condition} ]]; then
                        fnm use --silent-if-unchanged
                    fi
                ",
                version_file_exists_condition = version_file_exists_condition,
            ),
            VersionFileStrategy::Recursive => String::from(r"fnm use --silent-if-unchanged"),
        };
        Ok(formatdoc!(
            r"
                autoload -U add-zsh-hook
                _fnm_autoload_hook () {{
                    {autoload_hook}
                }}

                add-zsh-hook -D chpwd _fnm_autoload_hook
                add-zsh-hook chpwd _fnm_autoload_hook
            ",
            autoload_hook = autoload_hook
        ))
    }

    fn cleanup_on_exit(&self, multishell_path: &Path) -> Option<String> {
        let path = multishell_path.to_str()?;
        let path =
            super::windows_compat::maybe_fix_windows_path(path).unwrap_or_else(|| path.to_string());
        Some(formatdoc!(
            r#"
                if (( ! $+__fnm_cleanup_multishell_paths )); then
                    typeset -ga __fnm_cleanup_multishell_paths
                    autoload -U add-zsh-hook
                    _fnm_cleanup() {{
                        for p in "${{__fnm_cleanup_multishell_paths[@]}}"; do
                            \rm -rf "$p"
                        done
                    }}
                    add-zsh-hook zshexit _fnm_cleanup
                    trap _fnm_cleanup HUP INT TERM
                else
                    for p in "${{__fnm_cleanup_multishell_paths[@]}}"; do
                        \rm -rf "$p"
                    done
                    __fnm_cleanup_multishell_paths=()
                fi
                __fnm_cleanup_multishell_paths+=({path:?})
            "#,
            path = path
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn use_on_cd_removes_existing_hook_before_adding() {
        let output = Zsh.use_on_cd(&crate::config::FnmConfig::default()).unwrap();
        assert!(output.contains("add-zsh-hook -D chpwd _fnm_autoload_hook"));
    }

    #[test]
    fn cleanup_on_exit_registers_zshexit_hook() {
        let output = Zsh
            .cleanup_on_exit(Path::new("/tmp/fnm_multishells/123_456"))
            .unwrap();
        assert!(output.contains("add-zsh-hook zshexit _fnm_cleanup"));
        assert!(output.contains("/tmp/fnm_multishells/123_456"));
    }
}
