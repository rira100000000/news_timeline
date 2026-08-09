# frozen_string_literal: true

module NewsTimeline
  # Phase 3.5の出力（string key）を公開APIの戻り値（symbol key）に正規化する。
  # 「タイトル - URL」形式からのURL抽出、URL形式でない値と
  # vertexaisearchリダイレクトURLの除去もここで行う。
  module OutputFormatter
    module_function

    def format(phase3_5_result, logger: nil)
      {
        title: phase3_5_result["title"],
        description: phase3_5_result["description"],
        blocks: (phase3_5_result["blocks"] || []).map.with_index do |block, index|
          format_block(block, index, logger)
        end
      }
    end

    def format_block(block, index, logger)
      attrs = {
        event_year: block["event_year"],
        event_month: block["event_month"],
        event_day: block["event_day"],
        title: block["title"],
        content: block["content"],
        evidence_source_urls: extract_urls(block["evidence_source_urls"], logger),
        position: index
      }
      warn_anomalies(attrs, index, logger)
      attrs
    end

    def extract_urls(urls, logger)
      (urls || []).filter_map do |url|
        # 「タイトル - URL」形式の場合、URLだけを抽出
        url = url[%r{ - (https?://.+)}, 1] if url.match?(%r{ - https?://})

        next unless url.match?(%r{\Ahttps?://})

        # Phase 2.5で解決できなかったリダイレクトURLが残っていたら除去
        if url.include?("vertexaisearch.cloud.google.com/grounding-api-redirect")
          logger&.warn("vertexaiリダイレクトURLを検出してスキップ: #{url[0, 80]}...")
          next
        end

        url
      end
    end

    def warn_anomalies(attrs, index, logger)
      return unless logger

      label = "ブロック#{index + 1}「#{attrs[:title]}」"
      logger.warn "#{label}: event_year が 0 以下です (#{attrs[:event_year]})" if attrs[:event_year].to_i <= 0
      logger.warn "#{label}: evidence_source_urls が空です" if attrs[:evidence_source_urls].empty?
      logger.warn "#{label}: content が空です" if attrs[:content].to_s.empty?
    end
  end
end
