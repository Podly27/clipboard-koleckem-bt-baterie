func tr(_ czech: String, _ english: String) -> String {
    #if ENGLISH
    return english
    #else
    return czech
    #endif
}
