import Foundation

struct User {
    let id: Int
    let name: String
}

func greet(user: User) -> String {
    if user.name.isEmpty {
        return "Hello, stranger!"
    }
    return "Hello, \(user.name)!"

struct UserRepository {
    var users: [User] = []
}
