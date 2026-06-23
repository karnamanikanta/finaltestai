module Program

let greet name =
    let message = "Hello, " + name + "!
    printfn "%s" message

[<EntryPoint>]
let main argv =
    greet "World" |> ignore
    0
