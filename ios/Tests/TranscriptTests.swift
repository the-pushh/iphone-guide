import Foundation

@main
struct TranscriptTests {
    static func main() {
        expect(MessageContent("**Game:** Build a portfolio\n\nWhat time do you have?").suggestedGame == "Build a portfolio", "Game suggestion is available independently of Quests and Moves")
        expect(MessageContent("```text\n**Game:** Quoted example\n```").suggestedGame == nil, "quoted Games do not trigger exploration")
        expect(MessageContent("**Game:** ").suggestedGame == nil, "empty Game does not trigger exploration")
        var background = ConversationTranscript()
        background.receiveAssistantToken("A response ")
        let active = background.assistantID
        background.appendImport("Completed import gist")
        background.receiveAssistantToken("still streaming.")
        expect(background.messages.count == 2, "background import does not split a streaming reply")
        expect(background.messages[0].text == "A response still streaming.", "streamed tokens stay with the original reply")
        expect(background.assistantID == active, "streaming controls stay on the active reply")
        var speakingImport = ConversationTranscript()
        speakingImport.receiveUser("First fragment", final: true, at: 0)
        speakingImport.appendImport("Completed gist")
        speakingImport.receiveUser("second fragment", final: true, at: 0.2)
        expect(speakingImport.messages.count == 2, "background import does not split a user utterance")
        var transcript = ConversationTranscript()
        transcript.receiveUser("I want to plan", final: true, at: 0)
        let firstID = transcript.messages[0].id
        transcript.receiveUser("a trip this weekend.", final: true, at: 0.5)
        expect(transcript.messages.count == 1, "fragments share a bubble")
        expect(transcript.messages[0].text == "I want to plan a trip this weekend.", "fragments join with spaces")
        expect(transcript.messages[0].id == firstID, "bubble identity is stable")
        transcript.receiveUser("Somewhere", final: false, at: 0.7)
        transcript.receiveUser("Somewhere quiet", final: false, at: 0.8)
        expect(transcript.messages.count == 1, "interim text stays inside the bubble")
        expect(transcript.messages[0].displayText == "I want to plan a trip this weekend. Somewhere quiet", "interim hypotheses replace each other")
        transcript.receiveUser("Somewhere quiet.", final: true, at: 0.9)
        expect(transcript.messages[0].interim.isEmpty, "final replaces interim")
        expect(transcript.messages[0].text == "I want to plan a trip this weekend. Somewhere quiet.", "final appears only once")
        transcript.receiveUser("And near the sea.", final: true, at: 3.5)
        expect(transcript.messages.count == 2, "long transcript gap opens a bubble without speech events")

        var speech = ConversationTranscript()
        speech.userStartedSpeaking(at: 0)
        speech.receiveUser("A long", final: true, at: 1)
        speech.receiveUser("continuous thought.", final: true, at: 5)
        expect(speech.messages.count == 1, "continuous speech survives delayed finalization")
        speech.userStoppedSpeaking(at: 6)
        speech.userStartedSpeaking(at: 7)
        speech.receiveUser("With a short pause.", final: true, at: 8)
        expect(speech.messages.count == 1, "short speech pause keeps the bubble")
        speech.userStoppedSpeaking(at: 9)
        speech.userStartedSpeaking(at: 11)
        speech.receiveUser("Another thought.", final: true, at: 12)
        expect(speech.messages.count == 2, "two seconds of silence opens a bubble")
        speech.assistantStarted()
        speech.receiveUser("More detail.", final: true, at: 12.1)
        expect(speech.messages.count == 2, "LLM thinking does not split the user's thought")
        speech.receiveAssistant("Sounds")
        speech.receiveAssistant("good.")
        speech.userStartedSpeaking(at: 12.3)
        speech.receiveUser("Thanks.", final: true, at: 12.4)
        expect(speech.messages.count == 4, "a bot reply separates user turns")
        expect(speech.messages[2].text == "Sounds good.", "bot words remain joined")
        speech.appendTyped("One more thing")
        speech.receiveUser("A spoken follow-up", final: true, at: 12.5)
        expect(speech.messages.count == 6, "typed messages stay separate from speech")
        speech.endGroup()
        speech.receiveUser("After disconnect", final: true, at: 12.6)
        expect(speech.messages.count == 7, "disconnect closes the group")
        testMarkdown()
        print("All transcript and Markdown checks passed.")
    }

    static func testMarkdown() {
        let source = "Here is **your prompt**.\n\n```text\nFirst line.\n\nSecond line: café 🪷\n```\n\n[Open ChatGPT](https://chatgpt.com/)"
        var transcript = ConversationTranscript()
        transcript.assistantStarted()
        for character in source { transcript.receiveAssistantToken(String(character)) }
        expect(transcript.messages.count == 1, "streamed Markdown stays in one message")
        expect(transcript.messages[0].text == source, "token streaming preserves every newline and delimiter")
        let content = MessageContent(transcript.messages[0].text)
        expect(content.prompt == "First line.\n\nSecond line: café 🪷", "copy payload contains only exact prompt text")
        expect(content.actions == [.chatGPT], "explicit ChatGPT link becomes an action")
        expect(!content.markdown.contains("[Open ChatGPT]"), "action link is removed from rendered prose")
        expect(content.markdown.contains("**your prompt**"), "inline Markdown survives action extraction")
        let inside = MessageContent("```text\n[Open Claude](https://claude.ai/)\n```")
        expect(inside.actions.isEmpty, "links in code blocks never become actions")
        let unfinished = MessageContent("```text\nPartial prompt")
        expect(unfinished.prompt == nil && unfinished.markdown.contains("Partial prompt"), "unfinished streaming fences remain visible without enabling handoff")
        let malicious = MessageContent("[Open ChatGPT](https://chatgpt.com.attacker.test/)\n[Open Claude](javascript:alert(1))")
        expect(malicious.actions.isEmpty, "action destinations are exact allowlisted URLs")
        let repeated = MessageContent("[Open Claude](https://claude.ai)\n[Open Claude](https://claude.ai/)")
        expect(repeated.actions == [.claude], "duplicate action links produce one button")
        let tilde = MessageContent("~~~~text\nA prompt with ``` inside.\n~~~~\n[Open Claude](https://claude.ai/)")
        expect(tilde.prompt == "A prompt with ``` inside.", "matching fence length preserves inner backticks")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { print("FAIL: \(message)"); exit(1) }
        print("PASS: \(message)")
    }
}
