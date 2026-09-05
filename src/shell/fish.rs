use crate::version_file_strategy::VersionFileStrategy;

use super::shell::Shell;
use indoc::formatdoc;
use std::path::Path;

#[derive(Debug)]
pub struct Fish;

impl Shell for Fish {
    fn to_clap_shell(&self) -> clap_complete::Shell {
        clap_complete::Shell::Fish
    }

    fn path(&self, path: &Path) -> anyhow::Result<String> {
        let path = path
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("Can't convert path to string"))?;
        let path =
            super::windows_compat::maybe_fix_windows_path(path).unwrap_or_else(|| path.to_string());
        Ok(format!("set -gx PATH {path:?} $PATH;"))
    }

    fn set_env_var(&self, name: &str, value: &str) -> String {
        format!("set -gx {name} {value:?};")
    }

    fn use_on_cd(&self, config: &crate::config::FnmConfig) -> anyhow::Result<String> {
        let version_file_exists_condition = if config.resolve_engines() {
            "test -f .node-version -o -f .nvmrc -o -f package.json"
        } else {
            "test -f .node-version -o -f .nvmrc"
        };
        let autoload_hook = match config.version_file_strategy() {
            VersionFileStrategy::Local => formatdoc!(
                r"
                    if {version_file_exists_condition}
                        fnm use --silent-if-unchanged
                    end
                ",
                version_file_exists_condition = version_file_exists_condition,
            ),
            VersionFileStrategy::Recursive => String::from(r"fnm use --silent-if-unchanged"),
        };
        Ok(formatdoc!(
            r"
                function _fnm_autoload_hook --on-variable PWD --description 'Change Node version on directory change'
                    status --is-command-substitution; and return
                    {autoload_hook}
                end
            ",
            autoload_hook = autoload_hook
        ))
    }

    fn cleanup_on_exit(&self, multishell_path: &Path) -> Option<String> {
        let path = multishell_path.to_str()?;
        let path =
            super::windows_compat::maybe_fix_windows_path(path).unwrap_or_else(|| path.to_string());
        Some(formatdoc!(
            r"
                if not set -q __fnm_cleanup_multishell_paths
                    function __fnm_cleanup --on-event fish_exit
                        for p in $__fnm_cleanup_multishell_paths
                            rm -rf $p
                        end
                    end
                else
                    for p in $__fnm_cleanup_multishell_paths
                        rm -rf $p
                    end
                    set -e __fnm_cleanup_multishell_paths
                end
                set -g -a __fnm_cleanup_multishell_paths {path:?}
            ",
            path = path
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_on_exit_registers_fish_exit_event() {
        let output = Fish
            .cleanup_on_exit(Path::new("/tmp/fnm_multishells/123_456"))
            .unwrap();
        assert!(output.contains("function __fnm_cleanup --on-event fish_exit"));
        assert!(output.contains("/tmp/fnm_multishells/123_456"));
    }
}
