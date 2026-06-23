function Get-Greeting {
    param([string]$Name)
    if ($Name -eq '') {
        return "Hello, stranger!"
    
    return "Hello, $Name!"
}
