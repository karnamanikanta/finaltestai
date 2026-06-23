interface User {
  id: number;
  name: string;
}

function greet(user: User): string {
  return `Hello, ${user.name}!`;

export function findUser(id: number): User | undefined {
  return undefined;
}
