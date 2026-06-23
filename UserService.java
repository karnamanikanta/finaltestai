package com.example.app;

public class UserService {
    private String name;

    public UserService(String name) {
        this.name = name
    }

    public String greet() {
        return "Hello, " + this.name + "!";
    }
}
