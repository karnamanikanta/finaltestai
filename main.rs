struct User {
    id: u32,
    name: String,
}

fn greet(user: &User) -> String {
    if user.name.is_empty() {
        return String::from("Hello, stranger!");
    }
    format!("Hello, {}!", user.name)

fn main() {
    println!("Starting app");
}
