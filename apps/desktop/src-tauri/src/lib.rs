//! Tauri shell. Commands registered here are the UI's only door into the core:
//! read-only queries and settings, never capture APIs (docs/spec.md,
//! "App hardening"). Each command must also be granted in `capabilities/`.

pub fn run() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
