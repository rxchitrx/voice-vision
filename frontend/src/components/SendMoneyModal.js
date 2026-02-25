import React, { useState } from 'react';

const SendMoneyModal = ({ balance, paymentConfig, onClose, onSendMoney }) => {
  const [amount, setAmount] = useState('');
  const [description, setDescription] = useState('');

  const handleSubmit = (e) => {
    e.preventDefault();
    if (!amount || parseFloat(amount) <= 0) {
      alert('Please enter a valid amount');
      return;
    }
    if (parseFloat(amount) > balance) {
      alert('Insufficient balance');
      return;
    }
    if (!paymentConfig?.merchantId) {
      alert('Payment config unavailable');
      return;
    }
    if (parseFloat(amount) > paymentConfig.maxPerTxnAmount) {
      alert(`Amount exceeds max per transaction (₹${Number(paymentConfig.maxPerTxnAmount).toFixed(2)})`);
      return;
    }
    onSendMoney(parseFloat(amount), description);
    setAmount('');
    setDescription('');
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>Send Money</h2>
          <button className="close-btn" onClick={onClose}>X</button>
        </div>
        <form onSubmit={handleSubmit}>
          <div className="form-group">
            <label>Trusted Merchant</label>
            <input type="text" className="form-input" value={paymentConfig?.merchantDisplayName || 'Unavailable'} disabled />
          </div>
          <div className="form-group">
            <label>Amount</label>
            <input
              type="number"
              className="form-input"
              placeholder="0.00"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              step="0.01"
              min="0"
              max={Math.min(balance, Number(paymentConfig?.maxPerTxnAmount || balance))}
              required
            />
            <div className="balance-info">Available balance: ₹{balance.toFixed(2)}</div>
            {paymentConfig && (
              <div className="balance-info">Max per transaction: ₹{Number(paymentConfig.maxPerTxnAmount).toFixed(2)}</div>
            )}
          </div>
          <div className="form-group">
            <label>Description (Optional)</label>
            <input
              type="text"
              className="form-input"
              placeholder="e.g., Lunch payment"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
            />
          </div>
          <div className="modal-actions">
            <button type="button" className="btn btn-secondary" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="btn btn-success">
              Send Money
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default SendMoneyModal;
