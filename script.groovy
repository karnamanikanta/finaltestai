def greet(String name) {
    if (name == null || name.isEmpty()) {
        return "Hello, stranger!"
    }
    return "Hello, ${name}!"

def farewell(String name) {
    return "Goodbye, ${name}!"
}
