class User {
  final int id;
  final String name;

  User({required this.id, required this.name});

  String greet() {
    if (name.isEmpty) {
      return 'Hello, stranger!';
    }
    return 'Hello, $name!';

class UserRepository {
  final List<User> users = [];
}
