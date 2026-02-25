import axios from 'axios';

const API_BASE_URL = process.env.REACT_APP_API_URL || 'http://localhost:5001/api';

const api = axios.create({
  baseURL: API_BASE_URL,
  headers: {
    'Content-Type': 'application/json',
  },
});

export const getBalance = async () => {
  const response = await api.get('/balance');
  return response.data;
};

export const getTransactions = async () => {
  const response = await api.get('/transactions');
  return response.data;
};

export const getPaymentConfig = async () => {
  const response = await api.get('/payment-config');
  return response.data;
};

export const addFunds = async (amount, description) => {
  const response = await api.post('/add-funds', {
    amount: parseFloat(amount),
    description: description || '',
  });
  return response.data;
};

const createIdempotencyKey = () => {
  const randomPart = Math.random().toString(36).slice(2);
  return `web-${Date.now()}-${randomPart}`;
};

export const sendMoney = async (amount, merchantId, description) => {
  const response = await api.post('/send-money', {
    amount: parseFloat(amount),
    merchantId: merchantId || '',
    idempotencyKey: createIdempotencyKey(),
    authMethod: 'web_session',
    description: description || '',
  });
  return response.data;
};
