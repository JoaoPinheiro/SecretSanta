-- Test double: never communicates with Mail or sends a message.
on run argv
    if (count of argv) < 2 then error "Missing arguments."
    if item 2 of argv is "missing@example.com" then error "Dedicated account not found."
    if item 1 of argv is "check" then
        if (count of argv) is not 2 then error "Wrong account-check argument count."
        return "READY"
    end if
    if item 1 of argv is not "send" or (count of argv) is not 5 then error "Wrong send arguments."
    if item 3 of argv is "failure@example.com" then error "Submission failed."
    if item 3 of argv is "unconfirmed@example.com" then return "NOT_SUBMITTED"
    return "SUBMITTED"
end run
