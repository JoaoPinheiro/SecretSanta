-- Invoked by santa.swift. Values arrive as arguments, never executable code.
-- check ADDRESS performs a read-only account lookup; send submits one message.
on configuredSender(requestedAddress)
    set matches to {}
    tell application "Mail"
        set enabledAccounts to get every account whose enabled is true
        repeat with mailAccount in enabledAccounts
            set accountAddresses to get email addresses of mailAccount
            repeat with accountAddress in accountAddresses
                set addressText to contents of accountAddress
                ignoring case
                    if addressText is requestedAddress then
                        set end of matches to addressText
                    end if
                end ignoring
            end repeat
        end repeat
    end tell
    if (count of matches) is 0 then error "No enabled Apple Mail account has the dedicated sender address: " & requestedAddress
    if (count of matches) is not 1 then error "The dedicated sender address matches multiple Apple Mail accounts: " & requestedAddress
    return item 1 of matches
end configuredSender

on run argv
    if (count of argv) < 2 then error "Expected check ADDRESS or send ADDRESS RECIPIENT SUBJECT BODY."
    set operation to item 1 of argv
    if operation is "check" then
        if (count of argv) is not 2 then error "Expected check ADDRESS."
        my configuredSender(item 2 of argv)
        return "READY"
    end if
    if operation is not "send" or (count of argv) is not 5 then error "Expected send ADDRESS RECIPIENT SUBJECT BODY."
    set fromAddress to my configuredSender(item 2 of argv)
    set toAddress to item 3 of argv
    set subjectText to item 4 of argv
    set bodyText to item 5 of argv
    tell application "Mail"
        set outgoing to make new outgoing message with properties {visible:false, sender:fromAddress, subject:subjectText, content:bodyText}
        try
            set message signature of outgoing to missing value
            tell outgoing to make new to recipient at end of to recipients with properties {address:toAddress}
            set actualSender to extract address from (sender of outgoing)
            ignoring case
                if actualSender is not fromAddress then error "Mail selected a different sender; message was not sent."
            end ignoring
            if (count of to recipients of outgoing) is not 1 or (count of cc recipients of outgoing) is not 0 or (count of bcc recipients of outgoing) is not 0 then error "Unexpected message recipients; message was not sent."
            set actualRecipient to address of first to recipient of outgoing
            ignoring case
                if actualRecipient is not toAddress then error "Mail selected a different recipient; message was not sent."
            end ignoring
        on error failureText number failureNumber
            -- Only discard this newly created message before any send attempt.
            try
                delete outgoing
            end try
            error failureText number failureNumber
        end try
        if (send outgoing) is not true then error "Mail did not confirm submission. Check Mail before retrying."
    end tell
    return "SUBMITTED"
end run
