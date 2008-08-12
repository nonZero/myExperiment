class RemoveSitealizer < ActiveRecord::Migration
  def self.up
    drop_table :sitealizer
  end

  def self.down
    create_table :sitealizer do |t|
      t.column :path,       :string
      t.column :ip,         :string
      t.column :referer,    :string
      t.column :language,   :string
      t.column :user_agent, :string
      t.column :created_at, :datetime
      t.column :created_on, :date
    end
  end
end

