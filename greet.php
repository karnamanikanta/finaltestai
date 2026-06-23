<?php

function greet($name) {
    if (empty($name)) {
        return "Hello, stranger!";
    }
    return "Hello, " . $name . "!";

function farewell($name) {
    return "Goodbye, " . $name . "!";
}
