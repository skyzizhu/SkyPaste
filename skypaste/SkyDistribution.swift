enum AppDistribution {
    static var isAppStoreBuild: Bool {
        #if APP_STORE_BUILD
        return true
        #else
        return false
        #endif
    }
}
