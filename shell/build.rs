fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../assets/nvs.ide.ico");
    #[cfg(windows)]
    {
        // The necronomicon icon as the exe resource, so Explorer and the taskbar show it.
        let mut res = winres::WindowsResource::new();
        res.set_icon("../assets/nvs.ide.ico");
        res.set("ProductName", "nvs.ide");
        res.set("FileDescription", "nvs.ide: LazyVim with training wheels");
        if let Err(e) = res.compile() {
            println!("cargo:warning=icon resource not attached: {e}");
        }
    }
}
