use crate::version_file_strategy::VersionFileStrategy;

use super::shell::Shell;
use indoc::formatdoc;
use std::path::Path;

#[derive(Debug)]
pub struct Bash;

impl Shell for Bash {
    fn to_clap_shell(&self) -> clap_complete::Shell {
        clap_complete::Shell::Bash
    }

    fn path(&self, path: &Path) -> anyhow::Result<String> {
        let path = path
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("Can't convert path to string"))?;
        let path =
            super::windows_compat::maybe_fix_windows_path(path).unwrap_or_else(|| path.to_string());
        Ok(format!("export PATH={path:?}:\"$PATH\""))
    }

    fn set_env_var(&self, name: &str, value: &str) -> String {
        format!("export {name}={value:?}")
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
            r#"
                __fnm_use_if_file_found() {{
                    {autoload_hook}
                }}

                __fnmcd() {{
                    \cd "$@" || return $?
                    __fnm_use_if_file_found
                }}

                alias cd=__fnmcd
            "#,
            autoload_hook = autoload_hook
        ))
    }

    fn cleanup_on_exit(&self, multishell_path: &Path) -> Option<String> {
        let path = multishell_path.to_str()?;
        let path =
            super::windows_compat::maybe_fix_windows_path(path).unwrap_or_else(|| path.to_string());
        Some(formatdoc!(
            r#"
                if [ -z "${{__fnm_cleanup_multishell_paths+x}}" ]; then
                    __fnm_cleanup_multishell_paths=()
                    __fnm_cleanup() {{
                        for p in "${{__fnm_cleanup_multishell_paths[@]}}"; do
                            \rm -rf "$p"
                        done
                    }}
                    trap __fnm_cleanup EXIT
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
    fn cleanup_on_exit_registers_trap() {
        let output = Bash
            .cleanup_on_exit(Path::new("/tmp/fnm_multishells/123_456"))
            .unwrap();
        assert!(output.contains("trap __fnm_cleanup EXIT"));
        assert!(output.contains("/tmp/fnm_multishells/123_456"));
    }
}
