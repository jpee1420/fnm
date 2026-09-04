use crate::version_file_strategy::VersionFileStrategy;

use super::Shell;
use indoc::formatdoc;
use std::path::Path;

#[derive(Debug)]
pub struct PowerShell;

impl Shell for PowerShell {
    fn path(&self, path: &Path) -> anyhow::Result<String> {
        let current_path =
            std::env::var_os("PATH").ok_or_else(|| anyhow::anyhow!("Can't read PATH env var"))?;
        let mut split_paths: Vec<_> = std::env::split_paths(&current_path).collect();
        split_paths.insert(0, path.to_path_buf());
        let new_path = std::env::join_paths(split_paths)
            .map_err(|source| anyhow::anyhow!("Can't join paths: {source}"))?;
        let new_path = new_path
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("Can't read PATH"))?;
        Ok(self.set_env_var("PATH", new_path))
    }

    fn set_env_var(&self, name: &str, value: &str) -> String {
        format!(r#"$env:{name} = "{value}""#)
    }

    fn use_on_cd(&self, config: &crate::config::FnmConfig) -> anyhow::Result<String> {
        let version_file_exists_condition = if config.resolve_engines() {
            "(Test-Path .nvmrc) -Or (Test-Path .node-version) -Or (Test-Path package.json)"
        } else {
            "(Test-Path .nvmrc) -Or (Test-Path .node-version)"
        };
        let autoload_hook = match config.version_file_strategy() {
            VersionFileStrategy::Local => formatdoc!(
                r"
                    If ({version_file_exists_condition}) {{ & fnm use --silent-if-unchanged }}
                ",
                version_file_exists_condition = version_file_exists_condition,
            ),
            VersionFileStrategy::Recursive => String::from(r"fnm use --silent-if-unchanged"),
        };
        Ok(formatdoc!(
            r"
                function global:Set-FnmOnLoad {{ {autoload_hook} }}
                function global:Set-LocationWithFnm {{ param($path); if ($path -eq $null) {{Set-Location}} else {{Set-Location $path}}; Set-FnmOnLoad }}
                Set-Alias -Scope global cd_with_fnm Set-LocationWithFnm
                Set-Alias -Option AllScope -Scope global cd Set-LocationWithFnm
            ",
            autoload_hook = autoload_hook
        ))
    }

    fn cleanup_on_exit(&self, multishell_path: &Path) -> Option<String> {
        let path = multishell_path.to_str()?.replace('\'', "''");
        Some(formatdoc!(
            r"
                if (-not (Test-Path 'variable:global:__fnm_cleanup_multishell_paths')) {{
                    $global:__fnm_cleanup_multishell_paths = [System.Collections.Generic.List[string]]::new()
                    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {{
                        foreach ($p in $global:__fnm_cleanup_multishell_paths) {{
                            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue
                        }}
                    }} -SupportEvent -ErrorAction SilentlyContinue | Out-Null
                }}
                [void]$global:__fnm_cleanup_multishell_paths.Add('{path}')
            ",
            path = path
        ))
    }

    fn to_clap_shell(&self) -> clap_complete::Shell {
        clap_complete::Shell::PowerShell
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanup_on_exit_registers_engine_event() {
        let output = PowerShell
            .cleanup_on_exit(Path::new(
                r"C:\Users\user\AppData\Local\fnm_multishells\123_456",
            ))
            .unwrap();
        assert!(output.contains("Register-EngineEvent -SourceIdentifier PowerShell.Exiting"));
        assert!(output.contains(r"C:\Users\user\AppData\Local\fnm_multishells\123_456"));
    }
}
