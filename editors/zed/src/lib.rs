use std::fs;
use zed_extension_api::{
    self as zed, settings::LspSettings, Architecture, DownloadedFileType, GithubReleaseOptions,
    LanguageServerId, LanguageServerInstallationStatus, Os, Result,
};

const REPO: &str = "omdxp/fun";

struct FunExtension {
    cached_root: Option<String>,
}

impl FunExtension {
    fn exe_name() -> &'static str {
        match zed::current_platform().0 {
            Os::Windows => "fls.exe",
            _ => "fls",
        }
    }

    /// Downloads the latest release once and returns the directory that holds
    /// `bin/` and `share/fun/`.
    fn release_root(&mut self, id: &LanguageServerId) -> Result<String> {
        if let Some(root) = &self.cached_root {
            if fs::metadata(format!("{root}/bin/{}", Self::exe_name())).is_ok() {
                return Ok(root.clone());
            }
        }

        zed::set_language_server_installation_status(
            id,
            &LanguageServerInstallationStatus::CheckingForUpdate,
        );
        let release = zed::latest_github_release(
            REPO,
            GithubReleaseOptions {
                require_assets: true,
                pre_release: false,
            },
        )?;

        let (os, arch) = zed::current_platform();
        let arch = match arch {
            Architecture::Aarch64 => "aarch64",
            Architecture::X8664 => "x86_64",
            Architecture::X86 => return Err("Fun has no 32-bit x86 build".into()),
        };
        let (target, asset_name, file_type) = match os {
            Os::Mac => (
                format!("fun-{arch}-macos"),
                format!("fun-{arch}-macos.tar.gz"),
                DownloadedFileType::GzipTar,
            ),
            Os::Linux => (
                format!("fun-{arch}-linux-gnu"),
                format!("fun-{arch}-linux-gnu.tar.gz"),
                DownloadedFileType::GzipTar,
            ),
            Os::Windows => (
                format!("fun-{arch}-windows-gnu"),
                format!(
                    "fun-{arch}-windows-gnu-{}.zip",
                    release.version.trim_start_matches('v')
                ),
                DownloadedFileType::Zip,
            ),
        };

        let asset = release
            .assets
            .iter()
            .find(|a| a.name == asset_name)
            .ok_or_else(|| format!("no release asset named {asset_name}"))?;

        let version_dir = format!("fun-{}", release.version);
        let root = format!("{version_dir}/{target}");
        if fs::metadata(format!("{root}/bin/{}", Self::exe_name())).is_err() {
            zed::set_language_server_installation_status(
                id,
                &LanguageServerInstallationStatus::Downloading,
            );
            zed::download_file(&asset.download_url, &version_dir, file_type)
                .map_err(|e| format!("failed to download {asset_name}: {e}"))?;
            zed::make_file_executable(&format!("{root}/bin/{}", Self::exe_name()))?;
            zed::make_file_executable(&format!(
                "{root}/bin/{}",
                Self::exe_name().replace("fls", "fun")
            ))?;

            if let Ok(entries) = fs::read_dir(".") {
                for entry in entries.flatten() {
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    if name.starts_with("fun-") && name != version_dir {
                        fs::remove_dir_all(entry.path()).ok();
                    }
                }
            }
        }

        zed::set_language_server_installation_status(id, &LanguageServerInstallationStatus::None);
        self.cached_root = Some(root.clone());
        Ok(root)
    }
}

impl zed::Extension for FunExtension {
    fn new() -> Self {
        Self { cached_root: None }
    }

    fn language_server_command(
        &mut self,
        id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        let settings = LspSettings::for_worktree("fls", worktree).ok();
        let binary = settings.as_ref().and_then(|s| s.binary.as_ref());

        let mut env: Vec<(String, String)> = worktree.shell_env();
        let mut push_env = |key: &str, value: String| {
            env.retain(|(k, _)| k != key);
            env.push((key.to_string(), value));
        };

        let user_settings = settings.as_ref().and_then(|s| s.settings.as_ref());
        if let Some(v) = user_settings {
            if let Some(path) = v.get("fun_path").and_then(|p| p.as_str()) {
                push_env("FLS_FUN_PATH", path.to_string());
            }
            if let Some(dir) = v.get("stdlib_dir").and_then(|p| p.as_str()) {
                push_env("FUN_STDLIB_DIR", dir.to_string());
            }
            if v.get("debug").and_then(|d| d.as_bool()) == Some(true) {
                push_env("FLS_DEBUG", "1".to_string());
            }
        }

        let args = binary
            .and_then(|b| b.arguments.clone())
            .unwrap_or_default();

        if let Some(path) = binary.and_then(|b| b.path.clone()) {
            return Ok(zed::Command {
                command: path,
                args,
                env,
            });
        }

        if let Some(path) = worktree.which("fls") {
            return Ok(zed::Command {
                command: path,
                args,
                env,
            });
        }

        let root = self.release_root(id)?;
        let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
        let abs = |rel: &str| cwd.join(rel).to_string_lossy().to_string();
        let has_stdlib = env.iter().any(|(k, _)| k == "FUN_STDLIB_DIR");
        let has_fun = env.iter().any(|(k, _)| k == "FLS_FUN_PATH");
        if !has_stdlib {
            env.push(("FUN_STDLIB_DIR".into(), abs(&format!("{root}/share/fun"))));
        }
        if !has_fun {
            let fun = Self::exe_name().replace("fls", "fun");
            env.push(("FLS_FUN_PATH".into(), abs(&format!("{root}/bin/{fun}"))));
        }

        Ok(zed::Command {
            command: abs(&format!("{root}/bin/{}", Self::exe_name())),
            args,
            env,
        })
    }
}

zed::register_extension!(FunExtension);
