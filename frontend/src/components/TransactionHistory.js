import React from 'react';

const TransactionHistory = ({ transactions }) => {
  const formatDate = (dateString) => {
    const date = new Date(dateString);
    return date.toLocaleString();
  };

  return (
    <div className="card">
      <h2 className="transaction-history">Transaction History</h2>
      {transactions.length === 0 ? (
        <p>No transactions yet</p>
      ) : (
        transactions.map((transaction) => (
          <div key={transaction._id} className="transaction-item">
            <div className="transaction-details">
              <div><strong>{transaction.type === 'deposit' ? 'Deposit' : 'Withdrawal'}</strong></div>
              <div>{transaction.description || 'Transaction'}</div>
              {transaction.type === 'withdrawal' && transaction.merchantDisplayName && (
                <div style={{ fontSize: '12px', color: '#444' }}>Merchant: {transaction.merchantDisplayName}</div>
              )}
              <div style={{ fontSize: '12px', color: '#666' }}>{formatDate(transaction.createdAt)}</div>
            </div>
            <div className="transaction-amount">
              <div className={`amount ${transaction.type === 'deposit' ? 'positive' : 'negative'}`}>
                {transaction.type === 'deposit' ? '+' : '-'}₹{transaction.amount.toFixed(2)}
              </div>
              <div style={{ fontSize: '12px' }}>{transaction.status}</div>
            </div>
          </div>
        ))
      )}
    </div>
  );
};

export default TransactionHistory;
