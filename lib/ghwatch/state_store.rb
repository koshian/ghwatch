# frozen_string_literal: true

require "json"
require "fileutils"
require "sequel"

module Ghwatch
  class StateStore
    def initialize(path)
      FileUtils.mkdir_p(File.dirname(path))
      @db = Sequel.sqlite(path.to_s)
      migrate!
    end

    def tasks
      @db[:tasks].order(:created_at).all.map { |row| Task.from_row(row) }
    end

    def task(id)
      row = @db[:tasks].where(id: id).first
      row && Task.from_row(row)
    end

    def task_for_issue(number)
      row = @db[:tasks].where(issue_number: number).exclude(state: "done").first
      row && Task.from_row(row)
    end

    def task_for_pr(number)
      row = @db[:tasks].where(pr_number: number).exclude(state: "done").first
      row && Task.from_row(row)
    end

    def save_task(task)
      row = task.to_row.merge(updated_at: Time.now.to_i)
      existing = @db[:tasks].where(id: task.id).first

      if existing
        @db[:tasks].where(id: task.id).update(row)
      else
        @db[:tasks].insert(row.merge(created_at: Time.now.to_i))
      end

      task
    end

    def assessments
      @db[:issue_assessments].all.each_with_object({}) do |row, result|
        result[row[:issue_number]] = deserialize_assessment(row)
      end
    end

    def assessment(number)
      row = @db[:issue_assessments].where(issue_number: number).first
      row && deserialize_assessment(row)
    end

    def save_assessment(number, status:, reason:, comment:, signature:)
      row = {
        issue_number: number,
        status: status,
        reason: reason,
        comment: comment,
        issue_signature: signature,
        updated_at: Time.now.to_i
      }

      if @db[:issue_assessments].where(issue_number: number).first
        @db[:issue_assessments].where(issue_number: number).update(row)
      else
        @db[:issue_assessments].insert(row)
      end
    end

    def setting(key)
      @db[:settings].where(key: key.to_s).get(:value)
    end

    def set_setting(key, value)
      dataset = @db[:settings].where(key: key.to_s)
      if dataset.first
        dataset.update(value: value.to_s)
      else
        @db[:settings].insert(key: key.to_s, value: value.to_s)
      end
    end

    def transaction(&block)
      @db.transaction(&block)
    end

    private

    def migrate!
      @db.create_table?(:tasks) do
        String :id, primary_key: true
        Integer :issue_number
        Integer :pr_number
        String :state, null: false
        String :branch
        String :worktree
        String :last_issue_signature
        String :last_pr_signature
        String :last_review_signature
        String :human_marker
        Integer :retry_at
        Integer :attempts, null: false, default: 0
        String :last_model
        String :last_error, text: true
        String :metadata_json, text: true, null: false, default: "{}"
        Integer :created_at, null: false
        Integer :updated_at, null: false
        index :issue_number
        index :pr_number
        index :state
      end

      @db.create_table?(:issue_assessments) do
        Integer :issue_number, primary_key: true
        String :status, null: false
        String :reason, text: true
        String :comment, text: true
        String :issue_signature
        Integer :updated_at, null: false
      end

      @db.create_table?(:settings) do
        String :key, primary_key: true
        String :value, text: true
      end
    end

    def deserialize_assessment(row)
      {
        status: row[:status],
        reason: row[:reason],
        comment: row[:comment],
        issue_signature: row[:issue_signature],
        updated_at: row[:updated_at]
      }
    end
  end
end
