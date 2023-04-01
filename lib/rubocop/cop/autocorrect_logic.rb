# frozen_string_literal: true
require 'pry'
require 'pry-stack_explorer'
module RuboCop
  module Cop
    # This module encapsulates the logic for autocorrect behavior for a cop.
    module AutocorrectLogic
      def autocorrect?
        autocorrect_requested? && correctable? && autocorrect_enabled?
      end

      def autocorrect_with_disable_uncorrectable?
        autocorrect_requested? && disable_uncorrectable? && autocorrect_enabled?
      end

      def autocorrect_requested?
        @options.fetch(:autocorrect, false)
      end

      def correctable?
        self.class.support_autocorrect? || disable_uncorrectable?
      end

      def disable_uncorrectable?
        @options[:disable_uncorrectable] == true
      end

      def safe_autocorrect?
        cop_config.fetch('Safe', true) && cop_config.fetch('SafeAutoCorrect', true)
      end

      def autocorrect_enabled?
        # allow turning off autocorrect on a cop by cop basis
        return true unless cop_config

        return false if cop_config['AutoCorrect'] == false

        # :safe_autocorrect is a derived option based on several command-line
        # arguments - see RuboCop::Options#add_autocorrection_options
        return safe_autocorrect? if @options.fetch(:safe_autocorrect, false)

        true
      end

      private

      <<-COMMENT
        offense_rangeはParser::Source::Rangeクラス
        #<Parser::Source::Range /Users/xxx/Documents/github/rubocop/test_case.rb 73...96> の
        73はLayout/LineLengthがMax30なのでその警告の始まり。
        96は警告の終わり。つまりラインの最終端。
        offense_range.source の結果を見るとわかりやすい。"AAAAAAAAAA BBBB].freeze"
      COMMENT
      def disable_offense(offense_range)
        range = surrounding_heredoc(offense_range) || surrounding_percent_array(offense_range)

        if range
          <<-COMMENT
            surrounding_percent_array(offense_range)の結果としてrange.sourceには下記が入っている
            "%w[\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBB]"
            range_by_lines(range)はコード1行を取得している
            "ARRAY = %w[\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBB].freeze"
          COMMENT

          disable_offense_before_and_after(range_by_lines(range))
        else
          disable_offense_with_eol_or_surround_comment(offense_range)
        end
      end

      def disable_offense_with_eol_or_surround_comment(range)
        eol_comment = " # rubocop:todo #{cop_name}"
        needed_line_length = (range.source_line + eol_comment).length

        if needed_line_length <= max_line_length
          disable_offense_at_end_of_line(range_of_first_line(range), eol_comment)
        else
          disable_offense_before_and_after(range_by_lines(range))
        end
      end

      def surrounding_heredoc(offense_range)
        # The empty offense range is an edge case that can be reached from the Lint/Syntax cop.
        return nil if offense_range.empty?

        heredoc_nodes = processed_source.ast.each_descendant.select do |node|
          node.respond_to?(:heredoc?) && node.heredoc?
        end
        heredoc_nodes.map { |node| node.source_range.join(node.loc.heredoc_end) }
                     .find { |range| range.contains?(offense_range) }
      end

      def surrounding_percent_array(offense_range)
        return nil if offense_range.empty?

        <<-COMMENT
          percent_arrayの結果はこれ
          [s(:array,
            s(:str, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            s(:str, "BBBB"))]

          processed_source.astでtest_case.rbのファイル全体をASTにしている
          each_descendantでファイル全体 → ARRAY=から.freezeまでの一行 → ARRAY=の構文だけとブロックごとにeachしている
          processed_source.ast.each_descendant.to_a をすると理解しやすい
        COMMENT

        percent_array = processed_source.ast.each_descendant.select do |node|
          <<-COMMENT
            percent_literal?の中身は loc.begin&.source&.start_with?('%')
            ちなみに loc は location のエイリアス (わかりにくい勘弁してくれ)
            percent_array[0].loc.begin.sourceの結果は "%w[" だったのでtrueになる
            この時点で test_case.rb が下記のように改行されているためであろう
            ARRAY = %w[
            AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBB].freeze
          COMMENT

          node.array_type? && node.percent_literal?
        end

        <<-COMMENT
          offense_rangeは警告となる部分からだったが、source_rangeは対象となるコードを取得する。percent_array[0].sourceの結果は下記。
          "%w[\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA BBBB]"

          overlaps?で重なりあっているかを判定している
          overlaps?の中身は!disjoint?(other)となっており、処理が通る中身を下記に抜粋。otherにoffense_rangeが代入されている
          @begin_pos >= other.end_pos || other.begin_pos >= @end_pos

          この場所で動作するコードに書き換えるとこう
          range = percent_array[0].source_range
          range.begin_pos >= offense_range.end_pos || offense_range.begin_pos >= range.end_pos
          コードの始点が警告の終点よりも後ろにある || 警告の始点がコードの終点よりも後ろにある
          どちらかがtrueになるとコードと警告が重なっていないと判断される

          結果はfalse。overlaps?は!disjoint?なので反転してtrueとなる
        COMMENT

        percent_array.map(&:source_range).find { |range| range.overlaps?(offense_range) }
      end

      def range_of_first_line(range)
        begin_of_first_line = range.begin_pos - range.column
        end_of_first_line = begin_of_first_line + range.source_line.length

        Parser::Source::Range.new(range.source_buffer, begin_of_first_line, end_of_first_line)
      end

      # Expand the given range to include all of any lines it covers. Does not
      # include newline at end of the last line.
      def range_by_lines(range)
        begin_of_first_line = range.begin_pos - range.column

        last_line = range.source_buffer.source_line(range.last_line)
        last_line_offset = last_line.length - range.last_column
        end_of_last_line = range.end_pos + last_line_offset

        Parser::Source::Range.new(range.source_buffer, begin_of_first_line, end_of_last_line)
      end

      def max_line_length
        config.for_cop('Layout/LineLength')['Max'] || 120
      end

      def disable_offense_at_end_of_line(range, eol_comment)
        Corrector.new(range).insert_after(range, eol_comment)
      end

      def disable_offense_before_and_after(range_by_lines)
        <<-COMMENT
          range_with_newlineで1つsizeを増やしている理由はよくわからない
          leading_whitespaceは先頭の空白を見ている。インデントがあった場合に備えて？
          Corrector.newでrubocop:todoで覆うようにwrapしているようだが実際のコードはここではわからない
          Parser::Source::Rangeクラスではないので.sourceで見ることはできない
          ここでは中身を見ることができないようなので、correctorを生成したら次どのような処理になるのか全体の流れを見る必要がある
        COMMENT

        range_with_newline = range_by_lines.resize(range_by_lines.size + 1)
        leading_whitespace = range_by_lines.source_line[/^\s*/]

        Corrector.new(range_by_lines).wrap(
          range_with_newline,
          "#{leading_whitespace}# rubocop:todo #{cop_name}\n",
          "#{leading_whitespace}# rubocop:enable #{cop_name}\n"
        )
      end
    end
  end
end
