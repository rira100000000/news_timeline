# frozen_string_literal: true

require "net/http"
require "uri"

module NewsTimeline
  # グラウンディング検索が返すリダイレクトURL（vertexaisearch.cloud.google.com）を
  # 純Rubyで追跡して実URLに解決する。追跡できない場合は元のURLをそのまま返す。
  module UrlResolver
    USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    MAX_REDIRECTS = 5

    module_function

    def follow_redirect(url, max_redirects = MAX_REDIRECTS, logger: nil)
      return url if max_redirects <= 0

      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: 10, read_timeout: 10) do |http|
        request = Net::HTTP::Get.new(uri.request_uri)
        request["User-Agent"] = USER_AGENT
        http.request(request)
      end

      case response
      when Net::HTTPRedirection
        location = response["location"]
        location = URI.join(url, location).to_s if location&.start_with?("/")
        follow_redirect(location, max_redirects - 1, logger: logger)
      else
        url
      end
    rescue StandardError => e
      logger&.warn("リダイレクト追跡エラー: #{e.message}")
      url
    end
  end
end
