module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class RecebeeGateway < Gateway
      self.test_url = 'https://api-switcher-recebee-homolog.herokuapp.com/'
      self.live_url = 'https://api-switcher-recebee-homolog.herokuapp.com/'

      self.supported_countries = ['BR']
      self.default_currency = 'BRL'
      self.supported_cardtypes = [:visa, :master, :elo]

      self.homepage_url = 'https://recebee.com.br/'
      self.display_name = 'Recebee Gateway'

      STANDARD_ERROR_CODE_MAPPING = {}

      def initialize(options={})
        requires!(options, :access_token)
        @access_token = options[:access_token]
        @customer_id = 123

        super
      end

      def purchase(amount, payment_type, options = {})
        post = { installment_plan: {}, source: { card: {} } }
        add_amount(post, amount)
        add_payment_type(post, payment_type)
        add_credit_card(post, payment_type)
        add_installments(post, options) if options[:installments]
        add_metadata(post)

        commit(:post, "/v1/customers/#{@customer_id}/transactions", post)
      end

      # def authorize(amount, payment, options={})
      #   post = {}
      #   add_payment(post, payment)
      #   add_address(post, payment, options)
      #   add_customer_data(post, options)

      #   commit('authonly', post)
      # end

      # def capture(amount, authorization, options={})
      #   commit('capture', post)
      # end

      # def refund(amount, authorization, options={})
      #   commit('refund', post)
      # end

      # def void(authorization, options={})
      #   commit('void', post)
      # end

      # def verify(credit_card, options={})
      #   MultiResponse.run(:use_first_response) do |r|
      #     r.process { authorize(100, credit_card, options) }
      #     r.process(:ignore_result) { void(r.authorization, options) }
      #   end
      # end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        #byebug # talvez devesse filtrar dados sensíveis que passam por aqui
        transcript
      end

      private

      def add_amount(post, amount)
        post[:source][:amount] = amount
      end

      def add_payment_type(post, payment_type)
        post[:payment_type] = 'credit'
      end

      def add_credit_card(post, credit_card)
        post[:source][:usage] = 'single_use',
        post[:source][:type] = 'card'
        post[:source][:currency] = 'BRL'
        post[:source][:card][:holder_name] = credit_card.name
        post[:source][:card][:expiration_month] = "#{credit_card.month}"
        post[:source][:card][:expiration_year] = "#{credit_card.year}"
        post[:source][:card][:card_number] = credit_card.number
        post[:source][:card][:security_code] = credit_card.verification_value
      end

      def add_installments(post, options)
        post[:installment_plan][:mode] = 'interest_free'#byebug # era pra ser hardcoded essa opção?
        post[:installment_plan][:number_installments] = options[:installments]
      end

      def add_metadata(post)
        post[:description] = 'Spree'
      end

      # def add_customer_data(post, options)
      # end

      # def add_address(post, creditcard, options)
      # end

      # def add_payment(post, payment)
      # end

      def commit(method, url, parameters, options = {})
        response = api_request(method, url, parameters, options)

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          test: test?,
          error_code: error_code_from(response)
        )
      end

      def response_error(raw_response)
        parse(raw_response)
      rescue JSON::ParserError
        json_error(raw_response)
      end

      def json_error(raw_response)
        msg = 'Resposta inválida retornada pela API do Pagar.me. Por favor entre em contato com suporte@pagar.me se você continuar recebendo essa mensagem.'
        msg += "  (A resposta retornada pela API foi #{raw_response.inspect})"
        {
          'errors' => [{
            'message' => msg
          }]
        }
      end

      def success_from(response)
        success_purchase = response.key?('status') && response['status'] == 'succeeded'
        success_purchase
      end

      def message_from(response)
        if success_from(response)
          'Transação aprovada'
        else
          'Houve um erro ao criar a transação'
        end
      end

      def authorization_from(response)
        # este método aparentemente precisa retornar o ID da transação
        response['id'] if success_from(response)
      end

      def error_code_from(response)
        unless success_from(response)
          STANDARD_ERROR_CODE_MAPPING['processing_error']
        end
      end

      def api_request(method, endpoint, parameters = nil, options = {})
        raw_response = response = nil
        begin
          raw_response = ssl_request(method, self.live_url + endpoint, post_data(parameters), headers(options))
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = response_error(raw_response)
        rescue JSON::ParserError
          response = json_error(raw_response)
        end
        response
      end

      def parse(body)
        JSON.parse(body)
      end

      def post_data(post)
        post.collect { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join('&')
      end

      def headers(options)
        headers = {
          'Content-Type' => 'application/json',
          # 'User-Agent' => "ActiveMerchantBindings/#{ActiveMerchant::VERSION}",
          'Authorization' => "Bearer #{@access_token}"
        }

        headers
      end

      def test?
        live_url.include?('homolog')
      end
    end
  end
end
