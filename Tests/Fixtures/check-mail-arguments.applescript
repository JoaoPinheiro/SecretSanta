-- Literal argument comparison: punctuation and newlines must arrive unchanged.
on run argv
    set expectedBody to "Hi \"Alex\",\nLiteral $(echo unsafe); `echo unsafe` & backslash: \\"
    if argv is not {"send", "santa@example.com", "recipient@example.com", "Secret Santa — \"family\"", expectedBody} then error "Message arguments changed."
    return "SUBMITTED"
end run
