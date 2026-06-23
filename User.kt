data class User(val id: Int, val name: String)

fun greet(user: User): String {
    if (user.name.isEmpty()) {
        return "Hello, stranger!"
    }
    return "Hello, ${user.name}!"

class UserRepository {
    val users = mutableListOf<User>()
}
