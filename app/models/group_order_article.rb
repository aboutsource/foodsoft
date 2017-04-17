# A GroupOrderArticle stores the sum of how many items of an OrderArticle are ordered as part of a GroupOrder.
# The chronologically order of the Ordergroup - activity are stored in GroupOrderArticleQuantity
#
class GroupOrderArticle < ActiveRecord::Base

  belongs_to :group_order
  belongs_to :order_article
  has_many   :group_order_article_quantities, :dependent => :destroy

  validates_presence_of :group_order, :order_article
  validates_uniqueness_of :order_article_id, :scope => :group_order_id    # just once an article per group order

  scope :ordered, -> { includes(:group_order => :ordergroup).order('groups.name') }

  localize_input_of :result

  # Setter used in group_order_article#new
  # We have to create an group_order, if the ordergroup wasn't involved in the order yet
  def ordergroup_id=(id)
    self.group_order = GroupOrder.where(order_id: order_article.order_id, ordergroup_id: id).first_or_initialize
  end

  def ordergroup_id
    group_order.try!(:ordergroup_id)
  end

  # Updates the quantity/tolerance for this GroupOrderArticle by updating both GroupOrderArticle properties
  # and the associated GroupOrderArticleQuantities chronologically.
  #
  # See description of the ordering algorithm in the general application documentation for details.
  def update_quantities(quantity, tolerance)
    logger.debug("GroupOrderArticle[#{id}].update_quantities(#{quantity}, #{tolerance})")
    logger.debug("Current quantity = #{self.quantity}, tolerance = #{self.tolerance}")

    # When quantity and tolerance are zero, we don't serve any purpose
    if quantity == 0 && tolerance == 0
      logger.debug("Self-destructing since requested quantity and tolerance are zero")
      destroy!
      return
    end

    # Get quantities ordered with the newest item first.
    quantities = group_order_article_quantities.order('created_on DESC').to_a
    logger.debug("GroupOrderArticleQuantity items found: #{quantities.size}")

    if (quantities.size == 0)
      # There is no GroupOrderArticleQuantity item yet, just insert with desired quantities...
      logger.debug("No quantities entry at all, inserting a new one with the desired quantities")
      quantities.push(GroupOrderArticleQuantity.new(:group_order_article => self, :quantity => quantity, :tolerance => tolerance))
      self.quantity, self.tolerance = quantity, tolerance
    else
      # Decrease quantity/tolerance if necessary by going through the existing items and decreasing their values...
      i = 0
      while (i < quantities.size && (quantity < self.quantity || tolerance < self.tolerance))
        logger.debug("Need to decrease quantities for GroupOrderArticleQuantity[#{quantities[i].id}]")
        if (quantity < self.quantity && quantities[i].quantity > 0)
          delta = self.quantity - quantity
          delta = (delta > quantities[i].quantity ? quantities[i].quantity : delta)
          logger.debug("Decreasing quantity by #{delta}")
          quantities[i].quantity -= delta
          self.quantity -= delta
        end
        if (tolerance < self.tolerance && quantities[i].tolerance > 0)
          delta = self.tolerance - tolerance
          delta = (delta > quantities[i].tolerance ? quantities[i].tolerance : delta)
          logger.debug("Decreasing tolerance by #{delta}")
          quantities[i].tolerance -= delta
          self.tolerance -= delta
        end
        i += 1
      end
      # If there is at least one increased value: insert a new GroupOrderArticleQuantity object
      if (quantity > self.quantity || tolerance > self.tolerance)
        logger.debug("Inserting a new GroupOrderArticleQuantity")
        quantities.insert(0, GroupOrderArticleQuantity.new(
            :group_order_article => self,
            :quantity => (quantity > self.quantity ? quantity - self.quantity : 0),
            :tolerance => (tolerance > self.tolerance ? tolerance - self.tolerance : 0)
        ))
        # Recalc totals:
        self.quantity += quantities[0].quantity
        self.tolerance += quantities[0].tolerance
      end
    end

    # Check if something went terribly wrong and quantites have not been adjusted as desired.
    if (self.quantity != quantity || self.tolerance != tolerance)
      raise 'Invalid state: unable to update GroupOrderArticle/-Quantities to desired quantities!'
    end

    # Remove zero-only items.
    quantities = quantities.reject { | q | q.quantity == 0 && q.tolerance == 0}

    # Save
    transaction do
      quantities.each { | i | i.save! }
      self.group_order_article_quantities = quantities
      save!
    end
  end

  # Determines how many items of this article the Ordergroup receives.
  # Returns a hash with three keys: :quantity / :tolerance / :total
  #
  # See description of the ordering algorithm in the general application documentation for details.
  def calculate_result(total = nil)
    # return memoized result unless a total is given
    return @calculate_result if total.nil? && !@calculate_result.nil?

    quantity = tolerance = total_quantity = 0

    # Get total
    if not total.nil?
      logger.debug "<#{order_article.article.name}> => #{total} (given)"
    elsif order_article.article.is_a?(StockArticle)
      total = order_article.article.quantity
      logger.debug "<#{order_article.article.name}> (stock) => #{total}"
    else
      total = order_article.units_to_order * order_article.price.unit_quantity
      logger.debug "<#{order_article.article.name}> units_to_order #{order_article.units_to_order} => #{total}"
    end

    if total > 0
      # In total there are enough units ordered. Now check the individual result for the ordergroup (group_order).
      #
      # Get all GroupOrderArticleQuantities for this OrderArticle...
      order_quantities = GroupOrderArticleQuantity.where(group_order_article_id: order_article.group_order_article_ids).order('created_on')
      logger.debug "GroupOrderArticleQuantity records found: #{order_quantities.size}"

      # Determine quantities to be ordered...
      order_quantities.each do |goaq|
        q = [goaq.quantity, total - total_quantity].min
        total_quantity += q
        if goaq.group_order_article_id == self.id
          logger.debug "increasing quantity by #{q}"
          quantity += q
        end
        break if total_quantity >= total
      end

      # Determine tolerance to be ordered...
      if total_quantity < total
        logger.debug "determining additional items to be ordered from tolerance"
        order_quantities.each do |goaq|
          q = [goaq.tolerance, total - total_quantity].min
          total_quantity += q
          if goaq.group_order_article_id == self.id
            logger.debug "increasing tolerance by #{q}"
            tolerance += q
          end
          break if total_quantity >= total
        end
      end

      logger.debug "determined quantity/tolerance/total: #{quantity} / #{tolerance} / #{quantity + tolerance}"
    end

    # memoize result unless a total is given
    r = {:quantity => quantity, :tolerance => tolerance, :total => quantity + tolerance}
    @calculate_result = r if total.nil?
    r
  end

  # Returns order result,
  # either calcualted on the fly or fetched from result attribute
  # Result is set when finishing the order.
  def result(type = :total)
    self[:result] || calculate_result[type]
  end

  # This is used for automatic distribution, e.g., in order.finish! or when receiving orders
  def save_results!(article_total = nil)
    new_result = calculate_result(article_total)[:total]
    self.update_attribute(:result_computed, new_result)
    self.update_attribute(:result, new_result)
  end

  # Returns total price for this individual article
  # Until the order is finished this will be the maximum price or
  # the minimum price depending on configuration. When the order is finished it
  # will be the value depending of the article results.
  def total_price(order_article = self.order_article)
    if order_article.order.open?
      if FoodsoftConfig[:tolerance_is_costly]
        order_article.article.fc_price * (quantity + tolerance)
      else
        order_article.article.fc_price * quantity
      end
    else
      order_article.price.fc_price * result
    end
  end

  # Check if the result deviates from the result_computed
  def result_manually_changed?
    result != result_computed unless result.nil?
  end
end
