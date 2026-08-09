# frozen_string_literal: true

module NewsTimeline
  # Generator#generate の戻り値をMarkdownレポートに整形する（CLIのreport.md用）。
  module Report
    module_function

    def render(result, source_url: nil, user_intent: nil)
      lines = ["# #{result[:title]}", "", result[:description].to_s, ""]

      if source_url
        lines << "- 元記事: #{source_url}"
        lines << "- 調査観点: #{user_intent}" if user_intent
        lines << ""
      end

      result[:blocks].each do |block|
        lines << "## #{event_date(block)}: #{block[:title]}"
        lines << ""
        lines << block[:content].to_s
        lines << ""
        next if block[:evidence_source_urls].empty?

        lines << "情報源:"
        block[:evidence_source_urls].each { |url| lines << "- #{url}" }
        lines << ""
      end

      "#{lines.join("\n").rstrip}\n"
    end

    def event_date(block)
      date = block[:event_year].to_s
      date += format("-%02d", block[:event_month]) if block[:event_month]
      date += format("-%02d", block[:event_day]) if block[:event_month] && block[:event_day]
      date
    end
  end
end
