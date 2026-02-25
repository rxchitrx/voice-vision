const mongoose = require('mongoose');

const transactionSchema = new mongoose.Schema({
  type: {
    type: String,
    enum: ['deposit', 'withdrawal'],
    required: true
  },
  amount: {
    type: Number,
    required: true,
    min: 0
  },
  description: {
    type: String,
    default: ''
  },
  recipientPhone: {
    type: String,
    default: ''
  },
  merchantId: {
    type: String,
    default: ''
  },
  merchantDisplayName: {
    type: String,
    default: ''
  },
  idempotencyKey: {
    type: String,
    trim: true
  },
  authMethod: {
    type: String,
    default: ''
  },
  status: {
    type: String,
    enum: ['completed', 'pending', 'failed'],
    default: 'completed'
  },
  failureReason: {
    type: String,
    default: ''
  }
}, {
  timestamps: true
});

transactionSchema.index({ idempotencyKey: 1 }, { unique: true, sparse: true });

module.exports = mongoose.model('Transaction', transactionSchema);
